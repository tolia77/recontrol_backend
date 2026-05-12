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

  private

  def policy_verdict(_args)
    CommandPolicy::Verdict.new(decision: :allow, reason: :read_only_tool, resolved_binary: nil)
  end
end

class Phase19BaseTool < AiTools::Base
  NAME        = "phase19_base_tool"
  DESCRIPTION = "Phase 19 policy+confirmation test tool"
  HUMAN_LABEL = "Phase 19 base tool"
  SCHEMA = Dry::Schema.JSON do
    required(:binary).filled(:string)
    required(:args).array(:string)
    required(:cwd).filled(:string)
  end

  def build_payload(args)
    {
      command: "terminal.execute",
      payload: { binary: args[:binary], args: args[:args], cwd: args[:cwd] }
    }
  end

  def parse_response(response)
    {
      stdout: response.dig(:result, :stdout),
      exit_code: response.dig(:result, :exit_code)
    }
  end
end

RSpec.describe AiTools::Base do
  after(:context) do
    AiTools::REGISTRY.delete("test_echo")
    AiTools::REGISTRY.delete("phase19_base_tool")
  end

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

  describe "Phase 19 policy + sanitiser integration" do
    let(:valid_args) { { binary: "ls", args: ["-la"], cwd: "/tmp" } }

    let(:dispatch_response) do
      { id: "x", status: "ok", result: { stdout: "ok\e[0m", exit_code: 0 } }
    end

    let(:allow_verdict) do
      CommandPolicy::Verdict.new(decision: :allow, reason: :allowlisted, resolved_binary: "/usr/bin/ls")
    end
    let(:deny_verdict) do
      CommandPolicy::Verdict.new(decision: :deny, reason: :metacharacter, resolved_binary: nil)
    end
    let(:confirm_verdict) do
      CommandPolicy::Verdict.new(decision: :needs_confirm, reason: :deny_list, resolved_binary: nil)
    end

    def build_agent_runner(timeout: 0.5)
      captured = []
      runner = Object.new
      runner.define_singleton_method(:emit_requires_confirmation) { |env| captured << env }
      runner.define_singleton_method(:wall_clock_remaining) { timeout }
      runner.define_singleton_method(:with_pending_confirmation_queue) do |queue, &block|
        block.call(queue)
      end
      runner.define_singleton_method(:captured_envelopes) { captured }
      runner
    end

    def wait_for_confirmation_id(runner, timeout: 1.0)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      loop do
        env = runner.captured_envelopes.last
        return env[:confirmation_id] if env&.dig(:confirmation_id)
        break if (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) > timeout

        sleep 0.01
      end
      nil
    end

    def verdict_tool(verdict:, agent_runner: nil)
      klass = Class.new(Phase19BaseTool) do
        define_method(:policy_verdict) { |_args| verdict }
      end
      klass.new(device: device, agent_runner: agent_runner)
    end

    it "constructs without agent_runner for backward compatibility" do
      expect { Phase19BaseTool.new(device: device) }.not_to raise_error
    end

    it "constructs with an optional agent_runner kwarg" do
      expect { Phase19BaseTool.new(device: device, agent_runner: Object.new) }.not_to raise_error
    end

    it "defines private Base#policy_verdict" do
      expect(described_class.private_instance_methods(false)).to include(:policy_verdict)
    end

    it "default policy_verdict delegates to CommandPolicy.evaluate" do
      tool = Phase19BaseTool.new(device: device)
      expect(CommandPolicy).to receive(:evaluate).with(
        binary: "ls",
        args: ["-la"],
        cwd: "/",
        device: device
      ).and_return(allow_verdict)

      verdict = tool.send(:policy_verdict, { binary: "ls", args: ["-la"], cwd: "/" })
      expect(verdict).to eq(allow_verdict)
    end

    it "returns policy_denied and does not dispatch when verdict is :deny" do
      tool = verdict_tool(verdict: deny_verdict)
      expect(CommandBridge).not_to receive(:dispatch)
      expect(tool.call(valid_args)).to eq({ error: "policy_denied", reason: :metacharacter })
    end

    it "handles needs_confirm allow/deny/user_stopped/timeout outcomes and cleans up registry" do
      allow(CommandBridge).to receive(:dispatch).and_return(dispatch_response)

      runner = build_agent_runner(timeout: 0.3)
      tool = verdict_tool(verdict: confirm_verdict, agent_runner: runner)
      allow_thread_result = nil
      allow_thread = Thread.new { allow_thread_result = tool.call(valid_args) }
      allow_id = wait_for_confirmation_id(runner)
      expect(allow_id).to match(/\A[0-9a-f-]{36}\z/)
      expect(runner.captured_envelopes.last).to include(
        type: "requires_confirmation",
        confirmation_id: allow_id,
        tool_call_id: match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/),
        label: tool.class::HUMAN_LABEL,
        command: "ls",
        args: ["-la"],
        cwd: "/tmp",
        reason: :deny_list,
        zone: "deny_list"
      )
      ConfirmationRegistry.deliver(allow_id, { decision: "allow" })
      allow_thread.join(1.0)
      expect(allow_thread_result).to eq({ stdout: "ok", exit_code: 0 })
      expect(ConfirmationRegistry.fetch(allow_id)).to be_nil

      runner = build_agent_runner(timeout: 0.3)
      tool = verdict_tool(verdict: confirm_verdict, agent_runner: runner)
      deny_thread_result = nil
      deny_thread = Thread.new { deny_thread_result = tool.call(valid_args) }
      deny_id = wait_for_confirmation_id(runner)
      ConfirmationRegistry.deliver(deny_id, { decision: "deny" })
      deny_thread.join(1.0)
      expect(deny_thread_result).to eq({ error: "denied_by_operator" })
      expect(ConfirmationRegistry.fetch(deny_id)).to be_nil

      runner = build_agent_runner(timeout: 0.3)
      tool = verdict_tool(verdict: confirm_verdict, agent_runner: runner)
      stopped_thread_result = nil
      stopped_thread = Thread.new { stopped_thread_result = tool.call(valid_args) }
      stopped_id = wait_for_confirmation_id(runner)
      ConfirmationRegistry.deliver(stopped_id, { decision: "user_stopped" })
      stopped_thread.join(1.0)
      expect(stopped_thread_result).to eq({ error: "user_stopped_confirmation" })
      expect(ConfirmationRegistry.fetch(stopped_id)).to be_nil

      runner = build_agent_runner(timeout: 0.05)
      tool = verdict_tool(verdict: confirm_verdict, agent_runner: runner)
      timeout_result = tool.call(valid_args)
      timeout_id = runner.captured_envelopes.last[:confirmation_id]
      expect(timeout_result).to eq({ error: "confirmation_timeout" })
      expect(ConfirmationRegistry.fetch(timeout_id)).to be_nil
    end

    it "sanitises parsed responses on success" do
      tool = verdict_tool(verdict: allow_verdict)
      allow(CommandBridge).to receive(:dispatch).and_return(dispatch_response)
      expect(tool.call(valid_args)).to eq({ stdout: "ok", exit_code: 0 })
    end

    it "passes tool_timeout through parse bypass while still applying sanitiser" do
      tool = verdict_tool(verdict: allow_verdict)
      allow(CommandBridge).to receive(:dispatch).and_return({ error: "tool_timeout" })
      expect(tool).not_to receive(:parse_response)
      allow(ToolResultSanitiser).to receive(:call).and_call_original
      expect(ToolResultSanitiser).to receive(:call).with({ error: "tool_timeout" }).at_least(:once)
      expect(tool.call(valid_args)).to eq({ error: "tool_timeout" })
    end
  end
end
