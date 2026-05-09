# frozen_string_literal: true

require "rails_helper"

RSpec.describe AiTools::KillProcess do
  let(:user)   { create(:user) }
  let(:device) { create(:device, user: user) }
  let(:tool)   { described_class.new(device: device) }

  describe "constants" do
    it "uses kill_process as NAME and 'Kill process' as HUMAN_LABEL" do
      expect(described_class::NAME).to eq("kill_process")
      expect(described_class::HUMAN_LABEL).to eq("Kill process")
      expect(described_class::DESCRIPTION).to match(/destructive/i)
    end
  end

  describe "registration" do
    it "auto-registers under kill_process (D-10)" do
      expect(AiTools.fetch("kill_process")).to eq(described_class)
    end
  end

  describe ".to_openrouter_definition" do
    it "exposes pid as required integer (TOOL-03)" do
      params = described_class.to_openrouter_definition[:function][:parameters]
      expect(params["required"]).to include("pid")
      expect(params["properties"]["pid"]["type"]).to eq("integer")
    end
  end

  describe "#call" do
    it "dispatches process.kill with integer pid (TOOL-08)" do
      expect(CommandBridge).to receive(:dispatch).with(
        device: device,
        payload: { command: "process.kill", payload: { pid: 1234 } },
        tool_call_id: anything
      ).and_return({ id: "x", status: "ok", result: { killed: true } })

      expect(tool.call(pid: 1234)).to eq({ killed: true })
    end

    it "rejects string pid (D-12, TOOL-03 -- no shell substitution / no string coercion per RF-4)" do
      expect(CommandBridge).not_to receive(:dispatch)
      out = tool.call(pid: "1234")
      expect(out[:error]).to eq("invalid_arguments")
      expect(out[:details]).to have_key(:pid)
    end

    it "rejects negative pid" do
      expect(CommandBridge).not_to receive(:dispatch)
      out = tool.call(pid: -1)
      expect(out[:error]).to eq("invalid_arguments")
      expect(out[:details]).to have_key(:pid)
    end

    it "rejects zero pid" do
      expect(CommandBridge).not_to receive(:dispatch)
      out = tool.call(pid: 0)
      expect(out[:error]).to eq("invalid_arguments")
    end

    it "rejects float pid" do
      expect(CommandBridge).not_to receive(:dispatch)
      out = tool.call(pid: 3.14)
      expect(out[:error]).to eq("invalid_arguments")
    end

    it "returns killed: false plus desktop error when the kill fails" do
      allow(CommandBridge).to receive(:dispatch).and_return(
        { id: "x", status: "ok", result: { killed: false, error: "no_such_pid" } }
      )
      expect(tool.call(pid: 1234)).to eq({ killed: false, error: "no_such_pid" })
    end
  end
end
