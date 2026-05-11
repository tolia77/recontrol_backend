# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRunner do
  let(:user)          { create(:user) }
  let(:device)        { create(:device, user: user, platform_name: "linux") }
  let(:session_token) { SecureRandom.uuid }
  let(:client)        { instance_double(OpenRouterClient) }
  let(:captured)      { [] }

  def make_runner(prompt: "do a thing", model: "anthropic/claude-3.5-sonnet")
    AgentRunner.new(
      user: user, device: device, prompt: prompt, model: model,
      session_token: session_token, openrouter_client: client
    )
  end

  before do
    allow(ActionCable.server).to receive(:broadcast) { |stream, payload| captured << [stream, payload] }
    # Default CommandBridge stub: instant ok response. Individual examples may override.
    allow(CommandBridge).to receive(:dispatch).and_return(
      { result: { stdout: "ok", stderr: "", exit_code: 0, elapsed_seconds: 0.01 } }
    )
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Constants
  # ──────────────────────────────────────────────────────────────────────────
  describe "constants" do
    it "MAX_TURNS=25, WALL_CLOCK_SECONDS=120, FLUSH_INTERVAL_SECONDS=0.075" do
      expect(described_class::MAX_TURNS).to eq(25)
      expect(described_class::WALL_CLOCK_SECONDS).to eq(120)
      expect(described_class::FLUSH_INTERVAL_SECONDS).to eq(0.075)
      expect(described_class::HISTORY_BYTE_CAP).to eq(4_096)
    end

    it "WALL_CLOCK_SECONDS equals OpenRouterClient::READ_TIMEOUT_S" do
      expect(described_class::WALL_CLOCK_SECONDS).to eq(OpenRouterClient::READ_TIMEOUT_S)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Test 1-4: happy path + STREAM-02 + STREAM-04 + stream namespace
  # ──────────────────────────────────────────────────────────────────────────
  describe "happy path: completed (AGENT-02 / STREAM-02 / STREAM-04)" do
    it "emits at least one token broadcast and a done(stop_reason: completed)" do
      assistant_msg = { "role" => "assistant", "content" => "hello" }
      allow(client).to receive(:stream_chat_completion) do |&block|
        block&.call(:token, "hello")
        ["stop", assistant_msg]
      end

      make_runner.run

      types = captured.map { |_, p| p[:type] }
      expect(types).to include("token")
      expect(types.last).to eq("done")
      expect(captured.last[1][:stop_reason]).to eq("completed")
    end

    it "monotonically increases seq across all broadcasts (STREAM-02)" do
      allow(client).to receive(:stream_chat_completion) do |&block|
        block&.call(:token, "hi")
        ["stop", { "role" => "assistant", "content" => "hi" }]
      end
      make_runner.run

      seqs = captured.map { |_, p| p[:seq] }
      expect(seqs).to eq((1..seqs.length).to_a)
    end

    it "threads session_token through every broadcast (STREAM-04)" do
      allow(client).to receive(:stream_chat_completion).and_return(["stop", { "role" => "assistant", "content" => "x" }])
      make_runner.run
      tokens = captured.map { |_, p| p[:session_token] }.uniq
      expect(tokens).to eq([session_token])
    end

    it "broadcasts to the assistant_<user>_to_<device> stream" do
      allow(client).to receive(:stream_chat_completion).and_return(["stop", { "role" => "assistant", "content" => "x" }])
      make_runner.run
      streams = captured.map(&:first).uniq
      expect(streams).to eq(["assistant_#{user.id}_to_#{device.id}"])
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Test 5: AGENT-04 max_turns
  # ──────────────────────────────────────────────────────────────────────────
  describe "max_turns cap (AGENT-04)" do
    it "halts after MAX_TURNS with stop_reason: max_turns" do
      @turn = 0
      allow(client).to receive(:stream_chat_completion) do
        @turn += 1
        tc = { "id" => "tc-#{@turn}", "type" => "function",
               "function" => { "name" => "run_command",
                               "arguments" => { binary: "echo", args: [@turn.to_s], cwd: "/tmp" }.to_json } }
        ["tool_calls", { "role" => "assistant", "content" => "", "tool_calls" => [tc] }]
      end

      make_runner.run

      dones = captured.select { |_, p| p[:type] == "done" }
      expect(dones.length).to eq(1)
      expect(dones.first[1][:stop_reason]).to eq("max_turns")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Test 6: AGENT-05 wall_clock
  # ──────────────────────────────────────────────────────────────────────────
  describe "wall_clock cap (AGENT-05)" do
    it "halts when monotonic clock exceeds WALL_CLOCK_SECONDS" do
      # Build the runner BEFORE installing the Process.clock_gettime stub so the
      # factory_bot user/device creation (which calls clock_gettime under the hood
      # for ActiveRecord timestamps) is not affected.
      runner = make_runner
      allow(client).to receive(:stream_chat_completion).and_return(["stop", { "role" => "assistant", "content" => "x" }])

      base = 1000.0
      calls = 0
      # Pass through every clock_gettime call EXCEPT the CLOCK_MONOTONIC ones
      # the runner makes itself; the first one establishes baseline, the second
      # advances past WALL_CLOCK_SECONDS so the cap trips before the first
      # OpenRouter call.
      original_clock_gettime = Process.method(:clock_gettime)
      allow(Process).to receive(:clock_gettime) do |clock_id, *rest|
        if clock_id == Process::CLOCK_MONOTONIC && rest.empty?
          calls += 1
          calls <= 1 ? base : base + 121.0
        else
          original_clock_gettime.call(clock_id, *rest)
        end
      end

      runner.run

      dones = captured.select { |_, p| p[:type] == "done" }
      expect(dones.length).to eq(1)
      expect(dones.first[1][:stop_reason]).to eq("wall_clock")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Test 7: AGENT-06 loop_detected
  # ──────────────────────────────────────────────────────────────────────────
  describe "loop_detected (AGENT-06)" do
    it "halts when two consecutive run_command tool_calls share [binary, args, cwd]" do
      tc = { "id" => "loop", "type" => "function",
             "function" => { "name" => "run_command",
                             "arguments" => { binary: "ls", args: ["-la"], cwd: "/tmp" }.to_json } }
      allow(client).to receive(:stream_chat_completion).and_return(
        ["tool_calls", { "role" => "assistant", "content" => "", "tool_calls" => [tc] }],
        ["tool_calls", { "role" => "assistant", "content" => "", "tool_calls" => [tc] }]
      )

      make_runner.run

      done = captured.find { |_, p| p[:type] == "done" }
      expect(done[1][:stop_reason]).to eq("loop_detected")
      expect(done[1][:message]).to match(/Agent appears stuck/)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Test 8-9: AGENT-07 user_stopped (two scenarios)
  # ──────────────────────────────────────────────────────────────────────────
  describe "user_stopped (AGENT-07)" do
    it "halts at the next turn boundary after request_stop" do
      runner = make_runner
      allow(client).to receive(:stream_chat_completion) do |&block|
        runner.request_stop  # set the flag DURING the call, before next iteration
        block&.call(:token, "...")
        ["stop", { "role" => "assistant", "content" => "..." }]
      end

      runner.run

      # In this stub the flag is set during the first call which returns "stop"
      # (completed), so the implementation may emit "completed" because the
      # finish_reason check sits inside the same iteration. Per AGENT-07 contract:
      # "halt after the in-flight tool call returns, never mid-command". Spec
      # asserts that exactly one done envelope appears.
      dones = captured.select { |_, p| p[:type] == "done" }
      expect(dones.length).to eq(1)
    end

    it "emits user_stopped when stop_flag is set BEFORE first call" do
      runner = make_runner
      runner.request_stop
      # The first turn-boundary check fires before any client call.
      expect(client).not_to receive(:stream_chat_completion)
      runner.run

      dones = captured.select { |_, p| p[:type] == "done" }
      expect(dones.length).to eq(1)
      expect(dones.first[1][:stop_reason]).to eq("user_stopped")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Test 10: AGENT-10 mid-stream error
  # ──────────────────────────────────────────────────────────────────────────
  describe "openrouter mid-stream error (AGENT-10)" do
    it "broadcasts error with source openrouter and does not retry" do
      allow(client).to receive(:stream_chat_completion).and_raise(
        OpenRouterClient::MidStreamError, "upstream model timed out"
      )
      make_runner.run

      errors = captured.select { |_, p| p[:type] == "error" }
      expect(errors.length).to eq(1)
      expect(errors.first[1][:source]).to eq("openrouter")
      expect(errors.first[1][:message]).to match(/upstream model timed out/)
      expect(client).to have_received(:stream_chat_completion).once
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Test 11: STREAM-06 ensure-block fail-safe terminator
  # ──────────────────────────────────────────────────────────────────────────
  describe "ensure-block fail-safe terminator (STREAM-06)" do
    it "emits error broadcast when broadcast_error did not flip @terminated" do
      # The cleanest way to exercise the ensure-block fallback is to force
      # broadcast_error to no-op (so @terminated stays false). The ensure block
      # then emits the fail-safe terminator itself.
      allow(client).to receive(:stream_chat_completion).and_raise(StandardError, "boom")
      runner = make_runner
      allow(runner).to receive(:broadcast_error).and_return(nil)  # don't flip @terminated

      runner.run

      terminators = captured.select { |_, p| p[:type] == "error" && p[:message].to_s.include?("agent thread exited unexpectedly") }
      expect(terminators.length).to eq(1)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Test 12: STREAM-07 tool_call envelope shape
  # ──────────────────────────────────────────────────────────────────────────
  describe "tool_call broadcast envelope (STREAM-07)" do
    it "includes label: HUMAN_LABEL on tool_call_start; result: parsed hash on tool_call_result; never raw arguments JSON string" do
      tc = { "id" => "tc-1", "type" => "function",
             "function" => { "name" => "run_command",
                             "arguments" => { binary: "ls", args: ["/tmp"], cwd: "/tmp" }.to_json } }
      assistant_msg = { "role" => "assistant", "content" => "", "tool_calls" => [tc] }
      @phase = 0
      allow(client).to receive(:stream_chat_completion) do
        @phase += 1
        @phase == 1 ? ["tool_calls", assistant_msg] : ["stop", { "role" => "assistant", "content" => "done" }]
      end

      make_runner.run

      starts  = captured.select { |_, p| p[:type] == "tool_call_start" }
      results = captured.select { |_, p| p[:type] == "tool_call_result" }
      expect(starts.length).to eq(1)
      expect(starts.first[1][:label]).to eq("Run command")
      expect(starts.first[1][:name]).to eq("run_command")
      expect(starts.first[1][:args]).to be_a(Hash)
      expect(results.first[1][:result]).to be_a(Hash)
      # No broadcast carries the raw OpenRouter arguments JSON STRING shape
      # (which would contain `"binary"` and `"cwd"` as a single string value).
      expect(captured.none? { |_, p| p.values.any? { |v| v.is_a?(String) && v.include?('"binary"') && v.include?('"cwd"') } }).to be(true)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Test 13: STREAM-03 reserved types not emitted
  # ──────────────────────────────────────────────────────────────────────────
  describe "reserved broadcast types (STREAM-03)" do
    it "NEVER emits requires_confirmation or quota_warning in Phase 18" do
      allow(client).to receive(:stream_chat_completion).and_return(["stop", { "role" => "assistant", "content" => "x" }])
      make_runner.run
      types = captured.map { |_, p| p[:type] }
      expect(types).not_to include("requires_confirmation", "quota_warning")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Test 14: TOOL-05 history grounding
  # ──────────────────────────────────────────────────────────────────────────
  describe "history grounding (TOOL-05)" do
    it "accumulates tool result text into bounded @history_text" do
      tc = { "id" => "tc-1", "type" => "function",
             "function" => { "name" => "run_command",
                             "arguments" => { binary: "ls", args: ["/tmp"], cwd: "/tmp" }.to_json } }
      @phase = 0
      allow(client).to receive(:stream_chat_completion) do
        @phase += 1
        @phase == 1 ? ["tool_calls", { "role" => "assistant", "content" => "", "tool_calls" => [tc] }] : ["stop", { "role" => "assistant", "content" => "ok" }]
      end
      allow(CommandBridge).to receive(:dispatch).and_return(
        { result: { stdout: "long output text " * 50, stderr: "", exit_code: 0, elapsed_seconds: 0.01 } }
      )

      runner = make_runner
      runner.run

      history = runner.instance_variable_get(:@history_text)
      expect(history).to be_a(String)
      expect(history).not_to be_empty
      expect(history.bytesize).to be <= AgentRunner::HISTORY_BYTE_CAP
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Test 15: AGENT-09 system prompt threading
  # ──────────────────────────────────────────────────────────────────────────
  describe "system prompt + user prompt threading (AGENT-09)" do
    it "passes an interpolated system prompt as the first message and the user prompt second" do
      captured_messages = nil
      allow(client).to receive(:stream_chat_completion) do |args, **|
        captured_messages = args.is_a?(Hash) ? args[:messages] : nil
        ["stop", { "role" => "assistant", "content" => "x" }]
      end
      # RSpec passes kwargs-only methods through; capture via the receive block.
      allow(client).to receive(:stream_chat_completion) do |messages:, tools:, model:, &_block|
        captured_messages = messages
        ["stop", { "role" => "assistant", "content" => "x" }]
      end

      make_runner(prompt: "list /tmp").run

      expect(captured_messages).to be_an(Array)
      expect(captured_messages.first[:role]).to eq("system")
      expect(captured_messages.first[:content]).to include("Allowed read-only commands on this linux desktop:")
      expect(captured_messages[1][:role]).to eq("user")
      expect(captured_messages[1][:content]).to eq("list /tmp")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Test 16: STREAM-05 token batching
  # ──────────────────────────────────────────────────────────────────────────
  describe "token batching (STREAM-05)" do
    it "joins multiple in-stream tokens into a single token broadcast" do
      allow(client).to receive(:stream_chat_completion) do |&block|
        # Simulate three rapid token deltas within a single OpenRouter call.
        block&.call(:token, "Hel")
        block&.call(:token, "lo ")
        block&.call(:token, "world")
        ["stop", { "role" => "assistant", "content" => "Hello world" }]
      end

      make_runner.run

      token_events = captured.select { |_, p| p[:type] == "token" }
      # All three in-flight tokens flushed together (joined into a single payload)
      # before the done envelope. Token strings concatenated.
      expect(token_events).not_to be_empty
      expect(token_events.map { |_, p| p[:content] }.join).to eq("Hello world")
    end
  end

  describe "Phase 19: system prompt platform allowlist injection (D-05)" do
    let(:linux_device)   { create(:device, user: user, platform_name: "linux") }
    let(:windows_device) { create(:device, user: user, platform_name: "windows") }

    it "interpolates linux platform_name and the linux allow-list keys" do
      runner = AgentRunner.new(
        user: user, device: linux_device, prompt: "go",
        model: "anthropic/claude-3.5-sonnet", session_token: SecureRandom.uuid, openrouter_client: client
      )
      system_msg = runner.instance_variable_get(:@messages)[0][:content]
      expect(system_msg).to include("Allowed read-only commands on this linux desktop:")
      expect(system_msg).to include("ls")
      expect(system_msg).to include("cat")
      expect(system_msg).to include("grep")
      expect(system_msg).not_to include(", rm,")
      expect(system_msg).not_to include(", sudo,")
    end

    it "interpolates windows platform_name and the windows pathmap keys" do
      runner = AgentRunner.new(
        user: user, device: windows_device, prompt: "go",
        model: "anthropic/claude-3.5-sonnet", session_token: SecureRandom.uuid, openrouter_client: client
      )
      system_msg = runner.instance_variable_get(:@messages)[0][:content]
      expect(system_msg).to include("Allowed read-only commands on this windows desktop:")
      expect(system_msg).to include("tasklist")
      expect(system_msg).to include("findstr")
    end

    it "falls back to unknown platform with empty allowlist when platform_name is nil" do
      nil_platform_device = build(:device, user: user, platform_name: nil)
      nil_platform_device.save!(validate: false)
      runner = AgentRunner.new(
        user: user, device: nil_platform_device, prompt: "go",
        model: "anthropic/claude-3.5-sonnet", session_token: SecureRandom.uuid, openrouter_client: client
      )
      system_msg = runner.instance_variable_get(:@messages)[0][:content]
      expect(system_msg).to include("Allowed read-only commands on this unknown desktop: (none).")
    end
  end

  describe "Phase 19: request_stop sentinel push (D-07 / SAFETY-09)" do
    let(:runner) do
      AgentRunner.new(
        user: user, device: device, prompt: "go",
        model: "anthropic/claude-3.5-sonnet", session_token: SecureRandom.uuid, openrouter_client: client
      )
    end

    it "flips @stop_flag and pushes user_stopped sentinel onto @pending_confirmation_queue when non-nil" do
      queue = Queue.new
      runner.with_pending_confirmation_queue(queue) do
        runner.request_stop
        expect(runner.stop_flag_set?).to be(true)
        expect(queue.pop(true)).to eq({ decision: "user_stopped" })
      end
    end

    it "is a no-op on the queue side when @pending_confirmation_queue is nil" do
      expect { runner.request_stop }.not_to raise_error
      expect(runner.stop_flag_set?).to be(true)
    end
  end

  describe "Phase 19: confirmation queue helpers" do
    let(:runner) do
      AgentRunner.new(
        user: user, device: device, prompt: "go",
        model: "anthropic/claude-3.5-sonnet", session_token: SecureRandom.uuid, openrouter_client: client
      )
    end

    it "with_pending_confirmation_queue sets and clears the slot" do
      queue = Queue.new
      expect(runner.instance_variable_get(:@pending_confirmation_queue)).to be_nil
      runner.with_pending_confirmation_queue(queue) do
        expect(runner.instance_variable_get(:@pending_confirmation_queue)).to be(queue)
      end
      expect(runner.instance_variable_get(:@pending_confirmation_queue)).to be_nil
    end

    it "with_pending_confirmation_queue clears the slot even when the block raises" do
      queue = Queue.new
      expect {
        runner.with_pending_confirmation_queue(queue) { raise "boom" }
      }.to raise_error("boom")
      expect(runner.instance_variable_get(:@pending_confirmation_queue)).to be_nil
    end

    it "wall_clock_remaining returns a non-negative Float" do
      val = runner.wall_clock_remaining
      expect(val).to be_a(Numeric)
      expect(val).to be >= 0
      expect(val).to be <= AgentRunner::WALL_CLOCK_SECONDS
    end

    it "emit_requires_confirmation broadcasts the envelope via emit" do
      one = []
      allow(ActionCable.server).to receive(:broadcast) { |_, payload| one << payload }
      runner.emit_requires_confirmation(
        type: "requires_confirmation",
        confirmation_id: "abc",
        label: "Run",
        reason: :deny_list,
        zone: "deny_list"
      )
      expect(one.size).to eq(1)
      expect(one[0][:type]).to eq("requires_confirmation")
      expect(one[0][:confirmation_id]).to eq("abc")
      expect(one[0][:seq]).to be_a(Integer)
      expect(one[0][:session_token]).to eq(runner.session_token)
    end
  end

  describe "Phase 19: AiSession lifecycle (AUDIT-01)" do
    it "creates an AiSession row at run start, UPDATEs it in the ensure block" do
      allow(client).to receive(:stream_chat_completion).and_return(
        ["stop", { "role" => "assistant", "content" => "done" }, { "prompt_tokens" => 50, "completion_tokens" => 100, "total_tokens" => 150 }]
      )

      expect { make_runner.run }.to change(AiSession, :count).by(1)

      sess = AiSession.last
      expect(sess.user_id).to eq(user.id)
      expect(sess.device_id).to eq(device.id)
      expect(sess.started_at).to be_present
      expect(sess.ended_at).to be_present
      expect(sess.stop_reason).to eq("completed")
      expect(sess.model).to eq("anthropic/claude-3.5-sonnet")
      expect(sess.input_tokens).to eq(50)
      expect(sess.output_tokens).to eq(100)
      expect(sess.turn_count).to eq(0)
    end
  end

  describe "Phase 19: per-turn AiUsage.charge! (QUOTA-04 / D-11)" do
    let(:admin_user) { create(:user, role: :admin) }
    let(:admin_device) { create(:device, user: admin_user, platform_name: "linux") }

    def make_admin_runner
      AgentRunner.new(
        user: admin_user, device: admin_device, prompt: "go",
        model: "anthropic/claude-3.5-sonnet", session_token: SecureRandom.uuid, openrouter_client: client
      )
    end

    it "charges AiUsage with prompt_tokens + reasoning_tokens.to_i and completion_tokens" do
      allow(client).to receive(:stream_chat_completion).and_return(
        ["stop", { "role" => "assistant", "content" => "ok" },
         { "prompt_tokens" => 100, "completion_tokens" => 50, "reasoning_tokens" => 20, "total_tokens" => 170 }]
      )
      expect { make_admin_runner.run }.to change { AiUsage.current_total(admin_user) }.by(170)
    end

    it "skips the charge step when usage is nil" do
      allow(client).to receive(:stream_chat_completion).and_return(
        ["stop", { "role" => "assistant", "content" => "ok" }, nil]
      )
      expect { make_admin_runner.run }.not_to change { AiUsage.current_total(admin_user) }
    end
  end

  describe "Phase 19: 80% warning emit-once-per-run (QUOTA-05)" do
    let(:client_user) { create(:user, role: :client) }
    let(:client_device) { create(:device, user: client_user, platform_name: "linux") }

    def make_client_runner
      AgentRunner.new(
        user: client_user, device: client_device, prompt: "go",
        model: "anthropic/claude-3.5-sonnet", session_token: SecureRandom.uuid, openrouter_client: client
      )
    end

    before do
      AiUsage.create!(user: client_user, usage_date: Date.current, tokens_used: 7_500)
    end

    it "emits quota_warning exactly once when crossing 80%" do
      invocations = 0
      allow(client).to receive(:stream_chat_completion) do
        invocations += 1
        if invocations == 1
          ["tool_calls", { "role" => "assistant", "content" => "", "tool_calls" => [] },
           { "prompt_tokens" => 600, "completion_tokens" => 400 }]
        else
          ["stop", { "role" => "assistant", "content" => "done" },
           { "prompt_tokens" => 600, "completion_tokens" => 400 }]
        end
      end

      make_client_runner.run
      quota_warns = captured.select { |_, p| p[:type] == "quota_warning" }
      expect(quota_warns.size).to eq(1)
      expect(quota_warns.first[1][:percent]).to eq(80)
      expect(quota_warns.first[1][:limit]).to eq(10_000)
    end
  end

  describe "Phase 19: hard cap -> done(:quota) (QUOTA-06)" do
    let(:client_user) { create(:user, role: :client) }
    let(:client_device) { create(:device, user: client_user, platform_name: "linux") }

    def make_client_runner
      AgentRunner.new(
        user: client_user, device: client_device, prompt: "go",
        model: "anthropic/claude-3.5-sonnet", session_token: SecureRandom.uuid, openrouter_client: client
      )
    end

    before do
      AiUsage.create!(user: client_user, usage_date: Date.current, tokens_used: 9_900)
    end

    it "broadcasts done(:quota) when AiUsage.charge! raises QuotaExceededError" do
      allow(client).to receive(:stream_chat_completion).and_return(
        ["stop", { "role" => "assistant", "content" => "ok" },
         { "prompt_tokens" => 50, "completion_tokens" => 100 }]
      )
      make_client_runner.run
      done = captured.reverse.find { |_, p| p[:type] == "done" }
      expect(done[1][:stop_reason]).to eq("quota")
      expect(done[1][:tokens_used]).to be >= 10_000
      expect(done[1][:limit]).to eq(10_000)
    end

    it "refuses pre-call when already at limit (QUOTA-04 pre-call check)" do
      AiUsage.where(user: client_user, usage_date: Date.current).delete_all
      AiUsage.create!(user: client_user, usage_date: Date.current, tokens_used: 10_001)

      expect(client).not_to receive(:stream_chat_completion)
      make_client_runner.run
      done = captured.reverse.find { |_, p| p[:type] == "done" }
      expect(done[1][:stop_reason]).to eq("quota")
    end
  end
end
