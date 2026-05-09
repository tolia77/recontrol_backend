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
    let(:processes_150) do
      150.times.map { |i| { pid: i, command: "p#{i}", cpu_percent: 150 - i, memory_percent: 1.0 } }
    end

    it "dispatches process.list with empty payload (TOOL-08)" do
      expect(CommandBridge).to receive(:dispatch).with(
        device: device,
        payload: { command: "process.list", payload: {} },
        tool_call_id: anything
      ).and_return({ id: "x", status: "ok", result: { processes: processes_150 } })

      out = tool.call({})
      expect(out[:processes].length).to eq(100)
      expect(out[:processes].first[:cpu_percent]).to eq(150)  # highest first
      expect(out[:processes].last[:cpu_percent]).to eq(51)    # 150 - 99
    end

    it "returns all processes when fewer than TOP_N" do
      allow(CommandBridge).to receive(:dispatch).and_return(
        { id: "x", status: "ok", result: { processes: processes_150.first(20) } }
      )
      expect(tool.call({})[:processes].length).to eq(20)
    end

    it "returns empty array when desktop response has no :processes key" do
      allow(CommandBridge).to receive(:dispatch).and_return({ id: "x", status: "ok", result: {} })
      expect(tool.call({})).to eq({ processes: [] })
    end

    it "preserves original order for processes with equal cpu_percent (stable sort)" do
      tied = [
        { pid: 1, command: "a", cpu_percent: 10.0, memory_percent: 1.0 },
        { pid: 2, command: "b", cpu_percent: 10.0, memory_percent: 1.0 },
        { pid: 3, command: "c", cpu_percent: 10.0, memory_percent: 1.0 }
      ]
      allow(CommandBridge).to receive(:dispatch).and_return({ id: "x", status: "ok", result: { processes: tied } })
      pids = tool.call({})[:processes].map { |p| p[:pid] }
      expect(pids).to eq([1, 2, 3])
    end
  end
end
