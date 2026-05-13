# frozen_string_literal: true

require "rails_helper"

RSpec.describe AiTools::ListProcesses do
  let(:user)   { create(:user) }
  let(:device) { create(:device, user: user) }
  let(:tool)   { described_class.new(device: device) }

  describe "constants" do
    it "exposes name=list_processes, label=List processes, TOP_N=100" do
      expect(described_class::NAME).to eq("list_processes")
      expect(described_class::HUMAN_LABEL).to eq("List processes")
      expect(described_class::TOP_N).to eq(100)
    end
  end

  describe "registration" do
    it "auto-registers under list_processes (D-10)" do
      expect(AiTools.fetch("list_processes")).to eq(described_class)
    end
  end

  describe ".to_openrouter_definition" do
    it "produces a JSON-Schema-shaped parameters hash with type: object" do
      params = described_class.to_openrouter_definition[:function][:parameters]
      expect(params).to include("type" => "object")
    end
  end

  describe "#call" do
    # Wire shape from the desktop after CommandChannel#build_response_payload
    # deep-symbolises the JSON-parsed body. Field names are C# PascalCase
    # ({Pid, Name, MemoryMB, CpuTime, StartTime}) because the desktop's
    # ProcessInfo DTO serialises that way. parse_response renames them.
    let(:desktop_processes_150) do
      150.times.map do |i|
        { Pid: i, Name: "p#{i}", MemoryMB: 150 - i, CpuTime: "00:00:0#{i % 10}", StartTime: nil }
      end
    end

    it "dispatches terminal.listProcesses with empty payload (TOOL-08)" do
      expect(CommandBridge).to receive(:dispatch).with(
        device: device,
        payload: { command: "terminal.listProcesses", payload: {} },
        tool_call_id: anything
      ).and_return({ id: "x", status: "ok", result: desktop_processes_150 })

      out = tool.call({})
      expect(out[:processes].length).to eq(100)
      expect(out[:processes].first[:memory_mb]).to eq(150) # highest memory_mb first
      expect(out[:processes].last[:memory_mb]).to eq(51)   # 150 - 99
      expect(out[:processes].first).to include(:pid, :command, :memory_mb, :cpu_time)
    end

    it "returns all processes when fewer than TOP_N" do
      allow(CommandBridge).to receive(:dispatch).and_return(
        { id: "x", status: "ok", result: desktop_processes_150.first(20) }
      )
      expect(tool.call({})[:processes].length).to eq(20)
    end

    it "returns empty array when desktop response has no array result" do
      allow(CommandBridge).to receive(:dispatch).and_return({ id: "x", status: "ok", result: nil })
      expect(tool.call({})).to eq({ processes: [] })
    end

    it "preserves original order for processes with equal memory_mb (stable sort)" do
      tied = [
        { Pid: 1, Name: "a", MemoryMB: 10, CpuTime: "00:00:00", StartTime: nil },
        { Pid: 2, Name: "b", MemoryMB: 10, CpuTime: "00:00:00", StartTime: nil },
        { Pid: 3, Name: "c", MemoryMB: 10, CpuTime: "00:00:00", StartTime: nil }
      ]
      allow(CommandBridge).to receive(:dispatch).and_return({ id: "x", status: "ok", result: tied })
      pids = tool.call({})[:processes].map { |p| p[:pid] }
      expect(pids).to eq([1, 2, 3])
    end
  end

  describe "#policy_verdict (Phase 19 / D-03)" do
    let(:device) { instance_double("Device", platform_name: "linux") }
    let(:tool)   { described_class.new(device: device) }

    it "always returns :allow/:read_only_tool" do
      verdict = tool.send(:policy_verdict, {})
      expect(verdict.decision).to eq(:allow)
      expect(verdict.reason).to eq(:read_only_tool)
      expect(verdict.resolved_binary).to be_nil
    end
  end
end
