# frozen_string_literal: true

require "rails_helper"

RSpec.describe AiTools::ListFiles do
  let(:user)   { create(:user) }
  let(:device) { create(:device, user: user) }
  let(:tool)   { described_class.new(device: device) }

  describe "constants" do
    it "uses list_files as NAME and 'List files' as HUMAN_LABEL" do
      expect(described_class::NAME).to eq("list_files")
      expect(described_class::HUMAN_LABEL).to eq("List files")
      expect(described_class::MAX_ENTRIES).to eq(200)
    end
  end

  describe "registration" do
    it "auto-registers under list_files (D-10)" do
      expect(AiTools.fetch("list_files")).to eq(described_class)
    end
  end

  describe ".to_openrouter_definition" do
    it "exposes path as required string field (TOOL-04)" do
      params = described_class.to_openrouter_definition[:function][:parameters]
      expect(params["required"]).to include("path")
      expect(params["properties"]["path"]["type"]).to eq("string")
    end
  end

  describe "#call" do
    it "dispatches filemanager.list with the path argument (TOOL-08)" do
      expect(CommandBridge).to receive(:dispatch).with(
        device: device,
        payload: { command: "filemanager.list", payload: { path: "/home/user/projects" } },
        tool_call_id: anything
      ).and_return({
        id: "x", status: "ok",
        result: { entries: [{ name: "a.txt", type: "file" }, { name: "sub", type: "dir" }] }
      })

      expect(tool.call(path: "/home/user/projects")[:entries].length).to eq(2)
    end

    it "rejects missing path with invalid_arguments (D-12)" do
      expect(CommandBridge).not_to receive(:dispatch)
      out = tool.call({})
      expect(out[:error]).to eq("invalid_arguments")
      expect(out[:details]).to have_key(:path)
    end

    it "rejects empty path string" do
      expect(CommandBridge).not_to receive(:dispatch)
      out = tool.call(path: "")
      expect(out[:error]).to eq("invalid_arguments")
      expect(out[:details]).to have_key(:path)
    end

    it "caps entries at MAX_ENTRIES (200) when desktop returns more (TOOL-04)" do
      big = 250.times.map { |i| { name: "f#{i}", type: "file" } }
      allow(CommandBridge).to receive(:dispatch).and_return({ id: "x", status: "ok", result: { entries: big } })
      expect(tool.call(path: "/x")[:entries].length).to eq(200)
    end

    it "returns empty entries when desktop response has no :entries" do
      allow(CommandBridge).to receive(:dispatch).and_return({ id: "x", status: "ok", result: {} })
      expect(tool.call(path: "/x")).to eq({ entries: [] })
    end

    it "surfaces desktop allowlist-refusal errors as { error: <msg> }" do
      allow(CommandBridge).to receive(:dispatch).and_return(
        { id: "x", status: "error", error: "path_outside_allowlist" }
      )
      expect(tool.call(path: "/etc")).to eq({ error: "path_outside_allowlist" })
    end
  end

  describe "AiTools.all_definitions registry shape (post-plan-04)" do
    it "registers all four production tools" do
      expect(AiTools::REGISTRY.keys.sort).to include(
        "kill_process", "list_files", "list_processes", "run_command"
      )
    end

    it "AiTools.all_definitions returns at least the four production tools" do
      names = AiTools.all_definitions.map { |d| d[:function][:name] }
      expect(names).to include("kill_process", "list_files", "list_processes", "run_command")
    end
  end

  describe "#policy_verdict (Phase 19 / D-03)" do
    let(:device) { instance_double("Device", platform_name: "linux") }
    let(:tool)   { described_class.new(device: device) }

    it "always returns :allow/:read_only_tool" do
      verdict = tool.send(:policy_verdict, { path: "/tmp" })
      expect(verdict.decision).to eq(:allow)
      expect(verdict.reason).to eq(:read_only_tool)
      expect(verdict.resolved_binary).to be_nil
    end
  end
end
