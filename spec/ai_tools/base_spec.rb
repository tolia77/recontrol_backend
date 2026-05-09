# frozen_string_literal: true

require "rails_helper"

# Test subclass defined at top-level so the `Base.inherited` hook fires at file
# load (registers TestEchoTool under "test_echo"). The after(:context) hook
# unregisters it so it does not leak into other specs.
class TestEchoTool < AiTools::Base
  NAME        = "test_echo"
  DESCRIPTION = "Test tool for AiTools::Base spec"
  HUMAN_LABEL = "Test echo"
  SCHEMA = Dry::Schema.JSON do
    required(:foo).filled(:string)
  end

  def build_payload(args)
    { command: "test.echo", payload: { foo: args[:foo] } }
  end

  def parse_response(response)
    { echoed: response.dig(:result, :foo) }
  end
end

RSpec.describe AiTools::Base do
  after(:context) { AiTools::REGISTRY.delete("test_echo") }

  let(:user)   { create(:user) }
  let(:device) { create(:device, user: user) }
  let(:tool)   { TestEchoTool.new(device: device) }

  describe ".inherited registration (D-10)" do
    it "auto-registers the subclass under its NAME" do
      expect(AiTools.fetch("test_echo")).to eq(TestEchoTool)
    end
  end

  describe "AiTools.fetch" do
    it "raises ArgumentError on unknown tool name" do
      expect { AiTools.fetch("not_a_real_tool") }.to raise_error(ArgumentError, /Unknown AI tool/)
    end
  end

  describe "AiTools.all_definitions" do
    it "returns an array of registered tool definitions including this test tool" do
      defs = AiTools.all_definitions
      expect(defs).to be_an(Array)
      names = defs.map { |d| d[:function][:name] }
      expect(names).to include("test_echo")
    end
  end

  describe ".to_openrouter_definition (D-13)" do
    it "returns a function-typed OpenRouter tool entry with json_schema parameters" do
      definition = TestEchoTool.to_openrouter_definition
      expect(definition[:type]).to eq("function")
      expect(definition[:function][:name]).to eq("test_echo")
      expect(definition[:function][:description]).to eq("Test tool for AiTools::Base spec")

      params = definition[:function][:parameters]
      expect(params).to include("type" => "object")
      expect(params["properties"]).to have_key("foo")
      expect(params["required"]).to include("foo")
    end

    it "raises if NAME / DESCRIPTION / SCHEMA are missing on a subclass" do
      stub_const("AiTools::Stub", Class.new(AiTools::Base))
      expect { AiTools::Stub.to_openrouter_definition }
        .to raise_error(NotImplementedError, /NAME/)
    end
  end

  describe "#call template method" do
    let(:fake_response) { { id: "x", status: "ok", result: { foo: "echoed-foo" } } }

    it "validates, builds payload, dispatches via CommandBridge, parses response" do
      expect(CommandBridge).to receive(:dispatch).with(
        device: device,
        payload: { command: "test.echo", payload: { foo: "hi" } },
        tool_call_id: match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
      ).and_return(fake_response)

      expect(tool.call(foo: "hi")).to eq({ echoed: "echoed-foo" })
    end

    it "returns invalid_arguments envelope when args do not match SCHEMA (D-12)" do
      expect(CommandBridge).not_to receive(:dispatch)
      out = tool.call(foo: 123) # wrong type
      expect(out[:error]).to eq("invalid_arguments")
      expect(out[:details]).to be_a(Hash)
      expect(out[:details]).to have_key(:foo)
    end

    it "returns invalid_arguments when required field missing" do
      expect(CommandBridge).not_to receive(:dispatch)
      out = tool.call({})
      expect(out[:error]).to eq("invalid_arguments")
      expect(out[:details]).to have_key(:foo)
    end

    it "passes tool_timeout envelope through without calling parse_response (TOOL-07)" do
      allow(CommandBridge).to receive(:dispatch).and_return({ error: "tool_timeout" })
      expect(tool).not_to receive(:parse_response)
      expect(tool.call(foo: "hi")).to eq({ error: "tool_timeout" })
    end
  end
end
