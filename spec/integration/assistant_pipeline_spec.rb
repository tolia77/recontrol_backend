# frozen_string_literal: true

require "rails_helper"

# Phase-18 acceptance test. Exercises the full pipeline end-to-end:
#
#   AssistantChannel#run_prompt
#     -> Thread.new { AgentRunner#run }
#       -> mocked OpenRouterClient (stubbed via `instance_double`)
#       -> AiTools::* (REAL classes; registry populated by autoload at boot)
#       -> stubbed CommandBridge.dispatch (canned desktop response)
#         -> ActionCable.server.broadcast (intercepted -> `captured`)
#
# After this spec lands, ALL FIVE Phase-18 broadcast types are exercised
# (token, tool_call_start, tool_call_result, done, error) and the TWO RESERVED
# types (requires_confirmation, quota_warning) are proven absent across all
# captured broadcasts. AGENT-11 thread-kill timing is verified under 1.5 s.
#
# No production code is modified by this plan. Only the OpenRouter and
# CommandBridge boundaries are stubbed; everything in between (AssistantChannel,
# AgentRunner, AiTools registry + concrete tools, broadcast envelope assembly)
# runs as production code.

RSpec.describe "Assistant pipeline (Phase 18)" do
  # The channel-test DSL (`stub_connection`, `subscribe`, `subscription`,
  # `transmissions`, `perform`) is provided by `RSpec.describe ChannelClass,
  # type: :channel`. The outer describe above is a plain string group used
  # only for organizational read-out; the inner block below is what wires the
  # channel-test machinery in.
  describe AssistantChannel, type: :channel do
    let(:owner)  { create(:user) }
    let(:device) { create(:device, user: owner, platform_name: "linux") }

    let(:captured) { [] }
    let(:client)   { instance_double(OpenRouterClient) }

    before do
      stub_connection current_user: owner, client_type: "web", target_device: device

      # Capture every ActionCable broadcast emitted by AgentRunner. The payload
      # is the raw Ruby hash (symbol keys) -- not the JSON-roundtripped form
      # that `transmissions` returns.
      allow(ActionCable.server).to receive(:broadcast) do |stream, payload|
        captured << [stream, payload]
      end

      # Inject the mocked OpenRouterClient into the AgentRunner that the
      # channel constructs. AgentRunner.new accepts an `openrouter_client:`
      # kwarg; when supplied, it short-circuits the real `OpenRouterClient.new`
      # so we never hit Rails credentials in the integration path.
      allow(AgentRunner).to receive(:new).and_wrap_original do |orig, **kwargs|
        orig.call(**kwargs.merge(openrouter_client: client))
      end

      # Default CommandBridge stub: instant ok response. Each tool's
      # `parse_response` only reads the keys it needs; this single canned shape
      # satisfies all four tools.
      allow(CommandBridge).to receive(:dispatch).and_return(
        {
          result: {
            stdout: "ok",
            stderr: "",
            exit_code: 0,
            elapsed_seconds: 0.01,
            processes: [],
            entries: [],
            killed: true
          }
        }
      )

      subscribe
    end

    # Helper: wait for the runner thread spawned by run_prompt to finish so
    # all of its broadcasts are captured before assertions run.
    def join_runner_thread(timeout = 2.0)
      subscription.instance_variable_get(:@agent_thread)&.join(timeout)
    end

    # ──────────────────────────────────────────────────────────────────────
    # Test 1: multi-turn pipeline happy path (AGENT-02)
    # ──────────────────────────────────────────────────────────────────────
    describe "happy multi-turn path (AGENT-02)" do
      it "emits tool_call_start -> tool_call_result -> token -> done(completed)" do
        tc = {
          "id" => "tc-1",
          "type" => "function",
          "function" => {
            "name" => "run_command",
            "arguments" => { binary: "ls", args: ["/tmp"], cwd: "/tmp" }.to_json
          }
        }
        assistant_with_tools = { "role" => "assistant", "content" => "", "tool_calls" => [tc] }

        phase = 0
        allow(client).to receive(:stream_chat_completion) do |**_kwargs, &block|
          phase += 1
          if phase == 1
            ["tool_calls", assistant_with_tools]
          else
            block&.call(:token, "Done.")
            ["stop", { "role" => "assistant", "content" => "Done." }]
          end
        end

        perform :run_prompt, { "prompt" => "list /tmp", "model" => "anthropic/claude-3.5-sonnet" }
        join_runner_thread

        types = captured.map { |_, p| p[:type] }

        # All four expected types appear in the captured broadcast stream.
        expect(types).to include("tool_call_start", "tool_call_result", "token", "done")
        # Order invariant: the terminator is last.
        expect(types.last).to eq("done")
        expect(captured.last[1][:stop_reason]).to eq("completed")
        # Order invariant within the tool-dispatch block: start precedes result.
        start_idx  = types.index("tool_call_start")
        result_idx = types.index("tool_call_result")
        expect(start_idx).to be < result_idx
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # Test 2: broadcast envelope contract (STREAM-02 + STREAM-04)
    # ──────────────────────────────────────────────────────────────────────
    describe "broadcast envelope contract (STREAM-02 / STREAM-04)" do
      it "every broadcast carries monotone seq and a UUID session_token matching the accepted envelope" do
        allow(client).to receive(:stream_chat_completion) do |**_kwargs, &block|
          block&.call(:token, "hi")
          ["stop", { "role" => "assistant", "content" => "hi" }]
        end

        perform :run_prompt, { "prompt" => "x", "model" => "anthropic/claude-3.5-sonnet" }
        join_runner_thread

        seqs   = captured.map { |_, p| p[:seq] }
        tokens = captured.map { |_, p| p[:session_token] }.uniq

        expect(seqs).to eq((1..seqs.length).to_a)
        expect(seqs).to all(be_a(Integer).and(be >= 1))
        expect(tokens.length).to eq(1)
        expect(tokens.first).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)

        # STREAM-04: the channel-side `accepted` transmit MUST carry the same
        # session_token that the broadcasts carry.
        accepted = transmissions.find { |t| t["type"] == "accepted" }
        expect(accepted).not_to be_nil
        expect(accepted["session_token"]).to eq(tokens.first)
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # Test 3: STREAM-03 reserved types are NEVER emitted in Phase 18
    # ──────────────────────────────────────────────────────────────────────
    describe "reserved types stay reserved (STREAM-03 defensive)" do
      it "never emits requires_confirmation or quota_warning across happy/tool/error paths" do
        # Drive three different scenarios into the same captured stream so the
        # negative assertion holds across the union of paths.

        # Scenario A: simple happy completion.
        allow(client).to receive(:stream_chat_completion) do |**_kwargs, &block|
          block&.call(:token, "hello")
          ["stop", { "role" => "assistant", "content" => "hello" }]
        end
        perform :run_prompt, { "prompt" => "hi", "model" => "anthropic/claude-3.5-sonnet" }
        join_runner_thread

        # Scenario B: a tool-call turn followed by stop.
        tc = {
          "id" => "tc-r",
          "type" => "function",
          "function" => {
            "name" => "run_command",
            "arguments" => { binary: "ls", args: ["/tmp"], cwd: "/tmp" }.to_json
          }
        }
        phase_b = 0
        allow(client).to receive(:stream_chat_completion) do |**_kwargs, &block|
          phase_b += 1
          if phase_b == 1
            ["tool_calls", { "role" => "assistant", "content" => "", "tool_calls" => [tc] }]
          else
            block&.call(:token, "all done")
            ["stop", { "role" => "assistant", "content" => "all done" }]
          end
        end
        perform :run_prompt, { "prompt" => "list", "model" => "anthropic/claude-3.5-sonnet" }
        join_runner_thread

        # Scenario C: openrouter mid-stream error.
        allow(client).to receive(:stream_chat_completion).and_raise(
          OpenRouterClient::MidStreamError, "upstream error"
        )
        perform :run_prompt, { "prompt" => "boom", "model" => "anthropic/claude-3.5-sonnet" }
        join_runner_thread

        types = captured.map { |_, p| p[:type] }
        # The two reserved Phase-19 broadcast types appear nowhere across all
        # three scenarios. Plan 19 will lift this negative for those two
        # specific types (and only those two).
        expect(types).not_to include("requires_confirmation")
        expect(types).not_to include("quota_warning")
        # Sanity: the surface that DID get exercised covers every Phase-18 type
        # that any branch of the loop can emit.
        expect(types).to include("token", "tool_call_start", "tool_call_result", "done", "error")
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # Test 4: AGENT-10 openrouter mid-stream error -> exactly one error,
    # source: openrouter, no retry.
    # ──────────────────────────────────────────────────────────────────────
    describe "openrouter mid-stream error (AGENT-10)" do
      it "emits exactly one error broadcast with source=openrouter and does not retry" do
        allow(client).to receive(:stream_chat_completion).and_raise(
          OpenRouterClient::MidStreamError, "model upstream timeout"
        )

        perform :run_prompt, { "prompt" => "x", "model" => "anthropic/claude-3.5-sonnet" }
        join_runner_thread

        errors = captured.select { |_, p| p[:type] == "error" }
        expect(errors.length).to eq(1)
        expect(errors.first[1][:source]).to eq("openrouter")
        expect(errors.first[1][:message]).to match(/model upstream timeout/)
        expect(client).to have_received(:stream_chat_completion).once
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # Test 5: D-08 sequential multi-tool dispatch within a single turn
    # ──────────────────────────────────────────────────────────────────────
    describe "sequential multi-tool-call dispatch (D-08)" do
      it "dispatches and broadcasts two tool_calls in order: start(a) -> result(a) -> start(b) -> result(b)" do
        tc1 = {
          "id" => "tc-a",
          "type" => "function",
          "function" => {
            "name" => "run_command",
            "arguments" => { binary: "ls", args: ["/tmp"], cwd: "/tmp" }.to_json
          }
        }
        tc2 = {
          "id" => "tc-b",
          "type" => "function",
          "function" => { "name" => "list_processes", "arguments" => "{}" }
        }
        assistant = { "role" => "assistant", "content" => "", "tool_calls" => [tc1, tc2] }

        phase = 0
        allow(client).to receive(:stream_chat_completion) do |**_kwargs, &_block|
          phase += 1
          if phase == 1
            ["tool_calls", assistant]
          else
            ["stop", { "role" => "assistant", "content" => "ok" }]
          end
        end

        perform :run_prompt, { "prompt" => "x", "model" => "anthropic/claude-3.5-sonnet" }
        join_runner_thread

        relevant = captured
                   .map { |_, p| p }
                   .select { |p| %w[tool_call_start tool_call_result].include?(p[:type]) }
                   .map { |p| [p[:type], p[:tool_call_id]] }

        expect(relevant).to eq([
          ["tool_call_start",  "tc-a"],
          ["tool_call_result", "tc-a"],
          ["tool_call_start",  "tc-b"],
          ["tool_call_result", "tc-b"]
        ])
        # Sequential dispatch: CommandBridge.dispatch was called twice (once per tool).
        expect(CommandBridge).to have_received(:dispatch).twice
      end
    end

    # ──────────────────────────────────────────────────────────────────────
    # Test 6: AGENT-11 / STREAM-06 unsubscribed mid-stream -- thread killed
    # under 1.5 s and a terminating broadcast is emitted by the ensure block.
    # ──────────────────────────────────────────────────────────────────────
    describe "unsubscribed mid-stream (AGENT-11 / STREAM-06)" do
      it "kills the agent thread within 1.5 s and the ensure block emits a terminator" do
        # The OpenRouter mock signals when it has actually entered its long
        # sleep; the test then waits on that latch before issuing the kill.
        # Without the latch, `Thread#kill` could land before the runner reached
        # `AgentRunner#run`'s body -- in which case the run-level ensure block
        # (the one that emits the fail-safe terminator) never gets set up.
        entered_long_sleep = Concurrent::Event.new

        allow(client).to receive(:stream_chat_completion) do |**_kwargs, &_block|
          entered_long_sleep.set
          sleep 5
          ["stop", { "role" => "assistant", "content" => "never reached" }]
        end

        perform :run_prompt, { "prompt" => "x", "model" => "anthropic/claude-3.5-sonnet" }

        thread = subscription.instance_variable_get(:@agent_thread)
        expect(thread).to be_a(Thread)

        # Wait for the runner thread to actually enter the long sleep. Bound
        # the wait at 2 s so a regression here cannot wedge the suite.
        expect(entered_long_sleep.wait(2.0)).to be(true)

        # AGENT-11: unsubscribe -> AssistantChannel#unsubscribed runs
        # @agent_thread.kill + join(1.0).
        start_t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        subscription.unsubscribe_from_channel
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_t

        # 1.0 s join cap + a small overhead for the kill propagation. AGENT-11
        # contract: "kill within 1 second"; we allow 1.5 s here to absorb CI
        # scheduler jitter on a busy host.
        expect(elapsed).to be < 1.5
        expect(thread.alive?).to be false

        # STREAM-06: the runner's ensure block guarantees a terminator
        # broadcast (either a normal done/error or the fail-safe internal
        # error: "agent thread exited unexpectedly"). The invariant is that
        # AT LEAST ONE such broadcast was emitted before the thread unwound.
        terminators = captured.select { |_, p| %w[done error].include?(p[:type]) }
        expect(terminators.length).to be >= 1
      end
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # D-07: concurrent agent threads per device. The channel-test DSL above
  # covers a single subscription at a time. To verify that two AgentRunner
  # instances on the same (user, device) produce DISJOINT session_tokens and
  # PER-RUNNER monotone seq counters (no shared global counter), we
  # instantiate two AgentRunners directly and run them in two threads.
  # ──────────────────────────────────────────────────────────────────────────
  describe "concurrent runners for the same (user, device) (D-07)" do
    let(:user)     { create(:user) }
    let(:device)   { create(:device, user: user, platform_name: "linux") }
    let(:captured) { [] }

    before do
      allow(ActionCable.server).to receive(:broadcast) do |stream, payload|
        captured << [stream, payload]
      end
      allow(CommandBridge).to receive(:dispatch).and_return(
        { result: { stdout: "ok", stderr: "", exit_code: 0, elapsed_seconds: 0.01 } }
      )
    end

    it "produces disjoint session_tokens and per-session monotone seq counters" do
      token_a = SecureRandom.uuid
      token_b = SecureRandom.uuid

      client_a = instance_double(OpenRouterClient)
      client_b = instance_double(OpenRouterClient)
      allow(client_a).to receive(:stream_chat_completion) do |**_kwargs, &block|
        block&.call(:token, "A says hi")
        ["stop", { "role" => "assistant", "content" => "A says hi" }]
      end
      allow(client_b).to receive(:stream_chat_completion) do |**_kwargs, &block|
        block&.call(:token, "B says hi")
        ["stop", { "role" => "assistant", "content" => "B says hi" }]
      end

      runner_a = AgentRunner.new(
        user: user, device: device, prompt: "ping a",
        model: "anthropic/claude-3.5-sonnet",
        session_token: token_a, openrouter_client: client_a
      )
      runner_b = AgentRunner.new(
        user: user, device: device, prompt: "ping b",
        model: "anthropic/claude-3.5-sonnet",
        session_token: token_b, openrouter_client: client_b
      )

      [Thread.new { runner_a.run }, Thread.new { runner_b.run }].each(&:join)

      group_a = captured.select { |_, p| p[:session_token] == token_a }
      group_b = captured.select { |_, p| p[:session_token] == token_b }

      expect(group_a).not_to be_empty
      expect(group_b).not_to be_empty

      # Per-session monotone seq starting from 1. NOT a single shared counter
      # across both runners (which would yield interleaved 1..2N values).
      expect(group_a.map { |_, p| p[:seq] }).to eq((1..group_a.length).to_a)
      expect(group_b.map { |_, p| p[:seq] }).to eq((1..group_b.length).to_a)

      # Tokens are disjoint -- no broadcast from runner_a leaked into runner_b's
      # session_token, and vice versa.
      expect(group_a.map { |_, p| p[:session_token] }.uniq).to eq([token_a])
      expect(group_b.map { |_, p| p[:session_token] }.uniq).to eq([token_b])
      expect(token_a).not_to eq(token_b)

      # Both runners emit terminators (each ensure block fires).
      done_a = group_a.select { |_, p| p[:type] == "done" }
      done_b = group_b.select { |_, p| p[:type] == "done" }
      expect(done_a.length).to eq(1)
      expect(done_b.length).to eq(1)
    end
  end
end
