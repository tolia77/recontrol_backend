# frozen_string_literal: true

require "rails_helper"

RSpec.describe AiTools::RunCommand do
  let(:user)   { create(:user) }
  let(:device) { create(:device, user: user) }
  let(:tool)   { described_class.new(device: device) }

  describe "constants" do
    it "uses run_command as NAME and 'Run command' as HUMAN_LABEL" do
      expect(described_class::NAME).to eq("run_command")
      expect(described_class::HUMAN_LABEL).to eq("Run command")
      expect(described_class::DESCRIPTION).to match(/stdout/i).and match(/exit/i)
    end
  end

  describe ".to_openrouter_definition" do
    it "exposes binary/args/cwd as required JSON Schema fields (TOOL-01)" do
      params = described_class.to_openrouter_definition[:function][:parameters]
      expect(params["required"]).to include("binary", "args", "cwd")
      expect(params["properties"]["binary"]["type"]).to eq("string")
      expect(params["properties"]["cwd"]["type"]).to eq("string")
      expect(params["properties"]["args"]["type"]).to eq("array")
    end
  end

  describe "registration" do
    it "auto-registers under run_command (D-10)" do
      expect(AiTools.fetch("run_command")).to eq(described_class)
    end
  end

  describe "#call" do
    let(:dispatch_response) do
      {
        id: "x", status: "ok",
        result: { stdout: "foo\n", stderr: "", exit_code: 0, elapsed_seconds: 0.012 }
      }
    end

    it "dispatches a terminal.execute payload with binary/args/cwd (TOOL-08)" do
      expect(CommandBridge).to receive(:dispatch).with(
        device: device,
        payload: {
          command: "terminal.execute",
          payload: { binary: "ls", args: ["-la", "/tmp"], cwd: "/home/user" }
        },
        tool_call_id: anything
      ).and_return(dispatch_response)

      result = tool.call(binary: "ls", args: ["-la", "/tmp"], cwd: "/home/user")
      expect(result).to eq({ stdout: "foo\n", stderr: "", exit: 0, elapsed: 0.012 })
    end

    it "rejects missing cwd with invalid_arguments envelope (D-12, TOOL-06)" do
      expect(CommandBridge).not_to receive(:dispatch)
      out = tool.call(binary: "ls", args: [])
      expect(out[:error]).to eq("invalid_arguments")
      expect(out[:details]).to have_key(:cwd)
    end

    it "rejects non-string entries in args" do
      expect(CommandBridge).not_to receive(:dispatch)
      out = tool.call(binary: "ls", args: ["-la", 5], cwd: "/tmp")
      expect(out[:error]).to eq("invalid_arguments")
      expect(out[:details]).to have_key(:args)
    end

    it "rejects empty binary string" do
      expect(CommandBridge).not_to receive(:dispatch)
      out = tool.call(binary: "", args: [], cwd: "/tmp")
      expect(out[:error]).to eq("invalid_arguments")
      expect(out[:details]).to have_key(:binary)
    end
  end
end
