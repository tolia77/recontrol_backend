# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AgentRunner safety and quota integration" do
  let(:user) { create(:user) }
  let(:device) { create(:device, user: user, platform_name: "linux") }
  let(:session_token) { SecureRandom.uuid }
  let(:captured) { [] }

  def build_runner(client:, user: self.user, device: self.device)
    AgentRunner.new(
      user: user,
      device: device,
      prompt: "safety check",
      model: "anthropic/claude-3.5-sonnet",
      session_token: session_token,
      openrouter_client: client
    )
  end

  def wait_for_confirmation_id(captured, timeout: 1.0)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    loop do
      event = captured.find { |_, p| p[:type] == "requires_confirmation" }
      return event[1][:confirmation_id] if event
      return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > timeout

      sleep 0.01
    end
  end

  before do
    allow(ActionCable.server).to receive(:broadcast) do |stream, payload|
      captured << [stream, payload]
    end
    ConfirmationRegistry::REGISTRY.clear
  end

  it "SAFETY-09: Stop beats deny during confirmation and prevents dispatch" do
    tc = {
      "id" => "tc-stop",
      "type" => "function",
      "function" => {
        "name" => "run_command",
        "arguments" => { binary: "rm", args: ["-rf", "/tmp/test"], cwd: "/tmp" }.to_json
      }
    }
    client = instance_double(OpenRouterClient)
    allow(client).to receive(:stream_chat_completion).and_return(
      ["tool_calls", { "role" => "assistant", "content" => "", "tool_calls" => [tc] }],
      ["stop", { "role" => "assistant", "content" => "done" }]
    )
    allow(CommandBridge).to receive(:dispatch).and_raise("dispatch must not run while awaiting confirmation")

    runner = build_runner(client: client)
    thread = Thread.new { runner.run }
    expect(wait_for_confirmation_id(captured)).to be_present
    runner.request_stop
    thread.join(2.0)

    results = captured.select { |_, p| p[:type] == "tool_call_result" }
    expect(results.map { |_, p| p.dig(:result, :error) }).to include("user_stopped_confirmation")
    done = captured.reverse.find { |_, p| p[:type] == "done" }
    expect(done[1][:stop_reason]).to eq("user_stopped")
    expect(CommandBridge).not_to have_received(:dispatch)
  end

  it "SAFETY-08: deny aborts one tool call and loop continues to completed" do
    tc = {
      "id" => "tc-deny",
      "type" => "function",
      "function" => {
        "name" => "run_command",
        "arguments" => { binary: "rm", args: ["-rf", "/tmp/test"], cwd: "/tmp" }.to_json
      }
    }
    client = instance_double(OpenRouterClient)
    allow(client).to receive(:stream_chat_completion).and_return(
      ["tool_calls", { "role" => "assistant", "content" => "", "tool_calls" => [tc] }],
      ["stop", { "role" => "assistant", "content" => "continued after deny" }]
    )
    allow(CommandBridge).to receive(:dispatch).and_return({ result: { stdout: "unused", stderr: "", exit_code: 0, elapsed_seconds: 0.01 } })

    runner = build_runner(client: client)
    thread = Thread.new { runner.run }
    confirmation_id = wait_for_confirmation_id(captured)
    expect(confirmation_id).to be_present
    ConfirmationRegistry.deliver(confirmation_id, { decision: "deny" })
    thread.join(2.0)

    result = captured.find { |_, p| p[:type] == "tool_call_result" }
    expect(result[1].dig(:result, :error)).to eq("denied_by_operator")
    done = captured.reverse.find { |_, p| p[:type] == "done" }
    expect(done[1][:stop_reason]).to eq("completed")
  end

  it "SAFETY-11/12: sanitises AWS key from tool stdout before broadcast" do
    tc = {
      "id" => "tc-sanitize",
      "type" => "function",
      "function" => {
        "name" => "run_command",
        "arguments" => { binary: "ls", args: ["-la"], cwd: "/tmp" }.to_json
      }
    }
    client = instance_double(OpenRouterClient)
    allow(client).to receive(:stream_chat_completion).and_return(
      ["tool_calls", { "role" => "assistant", "content" => "", "tool_calls" => [tc] }],
      ["stop", { "role" => "assistant", "content" => "ok" }]
    )
    allow(CommandBridge).to receive(:dispatch).and_return(
      { result: { stdout: "AWS_SECRET_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE", stderr: "", exit_code: 0, elapsed_seconds: 0.01 } }
    )

    build_runner(client: client).run

    result = captured.find { |_, p| p[:type] == "tool_call_result" }
    stdout = result[1].dig(:result, :stdout).to_s
    expect(stdout).to include("[REDACTED]")
    expect(stdout).not_to include("AKIAIOSFODNN7EXAMPLE")
  end

  it "QUOTA-06: emits done(quota) when turn usage crosses hard cap" do
    AiUsage.create!(user: user, usage_date: Date.current, tokens_used: 9_900)
    client = instance_double(OpenRouterClient)
    allow(client).to receive(:stream_chat_completion).and_return(
      ["stop", { "role" => "assistant", "content" => "quota breach" }, { "prompt_tokens" => 150, "completion_tokens" => 0, "total_tokens" => 150 }]
    )

    build_runner(client: client).run

    done = captured.reverse.find { |_, p| p[:type] == "done" }
    expect(done[1][:stop_reason]).to eq("quota")
  end

  it "QUOTA-03: atomic charge race does not exceed role limit", :concurrent do
    concurrency_level = 4
    calls_per_thread = 30
    delta_per_call = 100
    role_limit = AiUsage::ROLE_LIMITS.fetch("client")

    expect(ActiveRecord::Base.connection_pool.size).to be >= 5

    gate = true
    threads = concurrency_level.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          true while gate
          calls_per_thread.times do
            begin
              AiUsage.charge!(user, input_tokens: delta_per_call, output_tokens: 0)
            rescue AiUsage::QuotaExceededError
              # expected around the cap boundary
            end
          end
        end
      end
    end
    gate = false
    threads.each(&:join)

    final_total = AiUsage.current_total(user)
    expect(final_total).to be <= role_limit
  ensure
    ActiveRecord::Base.connection_pool.disconnect!
  end
end
