# frozen_string_literal: true

require "rails_helper"
require "ostruct"
require_relative "../support/openrouter_stub"

RSpec.describe OpenRouterClient do
  let(:api_key) { "sk-or-test-1234567890abcdef" }
  let(:client)  { described_class.new(api_key: api_key, model: "anthropic/claude-sonnet-4.6") }

  describe "constants" do
    it "defines DEFAULT_MODEL, ALLOWED_MODELS, SYSTEM_PROMPT_TEMPLATE" do
      expect(described_class::DEFAULT_MODEL).to be_a(String)
      expect(described_class::ALLOWED_MODELS).to be_an(Array).and(be_frozen)
      expect(described_class::ALLOWED_MODELS).to include("anthropic/claude-sonnet-4.6")
      expect(described_class::SYSTEM_PROMPT_TEMPLATE).to include(
        "operator-side assistant",
        "UNTRUSTED external data",
        "same language as the user"
      )
    end

    it "READ_TIMEOUT_S equals AgentRunner's wall-clock cap of 120" do
      expect(described_class::READ_TIMEOUT_S).to eq(120)
    end

    it "exception hierarchy: MidStreamError < OpenRouterError < StandardError" do
      expect(described_class::MidStreamError.ancestors).to include(described_class::OpenRouterError, StandardError)
      expect(described_class::NetworkError.ancestors).to include(described_class::OpenRouterError)
      expect(described_class::RateLimitError.ancestors).to include(described_class::OpenRouterError)
    end
  end

  describe ".api_key" do
    around do |example|
      original = ENV.fetch("OPENROUTER_API_KEY", nil)
      example.run
    ensure
      original.nil? ? ENV.delete("OPENROUTER_API_KEY") : ENV["OPENROUTER_API_KEY"] = original
    end

    it "raises NetworkError when OPENROUTER_API_KEY env var is unset" do
      ENV.delete("OPENROUTER_API_KEY")
      expect { described_class.api_key }.to raise_error(described_class::NetworkError, /OPENROUTER_API_KEY/)
    end

    it "raises NetworkError when OPENROUTER_API_KEY env var is blank" do
      ENV["OPENROUTER_API_KEY"] = "   "
      expect { described_class.api_key }.to raise_error(described_class::NetworkError, /OPENROUTER_API_KEY/)
    end

    it "returns the stripped key when OPENROUTER_API_KEY is set" do
      ENV["OPENROUTER_API_KEY"] = "  sk-or-v1-test  "
      expect(described_class.api_key).to eq("sk-or-v1-test")
    end
  end

  describe "#initialize" do
    it "raises ArgumentError when model is not in ALLOWED_MODELS" do
      expect { described_class.new(api_key: api_key, model: "evil/llm") }.to raise_error(ArgumentError, /ALLOWED_MODELS/)
    end
  end

  describe "#stream_chat_completion" do
    let(:messages) { [{ role: "user", content: "hi" }] }
    let(:tools)    { [] }

    # Drive the on_data callback with the fixture string in chunks of N bytes.
    # This faithfully exercises EventStreamParser's chunk-boundary handling
    # without spinning up a real HTTP server (Faraday::Adapter::Test does not
    # support req.options.on_data the way we need for SSE).
    def drive_stream(fixture, chunk_size: 64)
      allow(client.instance_variable_get(:@conn)).to receive(:post) do |&block|
        req = OpenStruct.new(headers: {}, body: nil, options: OpenStruct.new)
        block.call(req)
        proc_cb = req.options.on_data
        # Slice the fixture into byte-sized pieces and feed each piece to the
        # callback. This mimics how Faraday's net_http adapter delivers chunks.
        fixture.bytes.each_slice(chunk_size) do |slice|
          chunk = slice.pack("c*").force_encoding("UTF-8")
          proc_cb.call(chunk, chunk.bytesize, nil)
        end
        nil
      end
    end

    it "accumulates token deltas and yields each fragment to the block" do
      drive_stream(OpenRouterStub.token_stream(fragments: %w[Hello there world]))
      yielded = []
      finish_reason, msg = client.stream_chat_completion(messages: messages, tools: tools) do |type, payload|
        yielded << [type, payload]
      end
      expect(finish_reason).to eq("stop")
      expect(msg["role"]).to eq("assistant")
      expect(msg["content"]).to eq("Hellothereworld")
      expect(yielded.map { |_, t| t }).to eq(%w[Hello there world])
    end

    it "concatenates a single tool_call's function.arguments fragments by index split across 5 chunks (RF-3)" do
      args_json = '{"binary":"ls","args":["-la","/tmp"],"cwd":"/tmp"}'
      drive_stream(OpenRouterStub.split_tool_call_stream(
        name: "run_command", arguments_json: args_json, chunks: 5, id: "call_x"
      ))
      finish_reason, msg = client.stream_chat_completion(messages: messages, tools: tools)
      expect(finish_reason).to eq("tool_calls")
      expect(msg["tool_calls"]).to be_an(Array).and(have_attributes(length: 1))
      tc = msg["tool_calls"].first
      expect(tc["id"]).to eq("call_x")
      expect(tc["function"]["name"]).to eq("run_command")
      expect(tc["function"]["arguments"]).to eq(args_json) # full reconstruction
    end

    it "preserves order of two parallel tool_calls by index (0 then 1)" do
      drive_stream(OpenRouterStub.two_tool_call_stream)
      _, msg = client.stream_chat_completion(messages: messages, tools: tools)
      expect(msg["tool_calls"].map { |tc| tc["function"]["name"] }).to eq(%w[run_command list_processes])
    end

    it "raises MidStreamError when finish_reason == 'error' (AGENT-10)" do
      drive_stream(OpenRouterStub.mid_stream_error_stream(message: "upstream model timed out"))
      expect { client.stream_chat_completion(messages: messages, tools: tools) }
        .to raise_error(described_class::MidStreamError, /upstream model timed out/)
    end

    it "treats `data: [DONE]` as end-of-stream without invoking JSON.parse on the literal" do
      # If [DONE] reached JSON.parse, we'd get a JSON::ParserError. The fixture
      # below has zero data lines but a [DONE] terminator. The token block
      # must not yield.
      drive_stream(OpenRouterStub.done_line)
      yielded = []
      finish_reason, msg = client.stream_chat_completion(messages: messages, tools: tools) do |type, t|
        yielded << [type, t]
      end
      expect(yielded).to be_empty
      expect(msg["content"]).to eq("")
      expect(finish_reason).to be_nil
    end

    it "ignores `: OPENROUTER PROCESSING` heartbeat comment lines between data events" do
      fixture = OpenRouterStub.heartbeat_line + OpenRouterStub.token_stream(fragments: %w[ok])
      drive_stream(fixture)
      _, msg = client.stream_chat_completion(messages: messages, tools: tools)
      expect(msg["content"]).to eq("ok")
    end

    it "raises ArgumentError when called with a model not in ALLOWED_MODELS" do
      expect {
        client.stream_chat_completion(messages: messages, tools: tools, model: "evil/llm")
      }.to raise_error(ArgumentError, /ALLOWED_MODELS/)
    end
  end

  describe "Phase 19: SYSTEM_PROMPT_TEMPLATE interpolation (D-05)" do
    it "contains the platform and allowlist interpolation points" do
      expect(described_class::SYSTEM_PROMPT_TEMPLATE).to include("%{platform}")
      expect(described_class::SYSTEM_PROMPT_TEMPLATE).to include("%{allowlist}")
    end

    it "contains the locked allowed-commands line shape" do
      expect(described_class::SYSTEM_PROMPT_TEMPLATE).to match(
        /Allowed read-only commands on this %\{platform\} desktop: %\{allowlist\}\./
      )
    end

    it "still contains the AGENT-09 locale directive" do
      expect(described_class::SYSTEM_PROMPT_TEMPLATE).to include("same language as the user's last message")
    end

    it "format(...) produces an interpolated, non-frozen String" do
      out = format(described_class::SYSTEM_PROMPT_TEMPLATE, platform: "linux", allowlist: "ls, cat, grep")
      expect(out).to include("Allowed read-only commands on this linux desktop: ls, cat, grep.")
      expect(out).not_to be_frozen
    end
  end

  describe "Phase 19: stream_chat_completion captures `usage` block (3-tuple return)" do
    let(:messages) { [{ role: "user", content: "hi" }] }
    let(:tools)    { [] }

    def drive_stream(fixture, chunk_size: 64)
      allow(client.instance_variable_get(:@conn)).to receive(:post) do |&block|
        req = OpenStruct.new(headers: {}, body: nil, options: OpenStruct.new)
        block.call(req)
        proc_cb = req.options.on_data
        fixture.bytes.each_slice(chunk_size) do |slice|
          chunk = slice.pack("c*").force_encoding("UTF-8")
          proc_cb.call(chunk, chunk.bytesize, nil)
        end
        nil
      end
    end

    it "returns [finish_reason, assistant_message, usage] when SSE final event includes usage" do
      fixture =
        OpenRouterStub.data_line(
          "choices" => [{ "index" => 0, "delta" => { "content" => "ok" } }]
        ) +
        OpenRouterStub.data_line(
          "choices" => [{ "index" => 0, "delta" => {}, "finish_reason" => "stop" }],
          "usage" => { "prompt_tokens" => 50, "completion_tokens" => 100, "total_tokens" => 150 }
        ) +
        OpenRouterStub.done_line
      drive_stream(fixture)

      finish_reason, _msg, usage = client.stream_chat_completion(messages: messages, tools: tools)
      expect(finish_reason).to eq("stop")
      expect(usage["prompt_tokens"]).to eq(50)
      expect(usage["completion_tokens"]).to eq(100)
      expect(usage["total_tokens"]).to eq(150)
    end

    it "returns nil for usage when SSE stream has no usage block" do
      drive_stream(OpenRouterStub.token_stream(fragments: ["ok"], finish_reason: "stop"))
      _finish_reason, _msg, usage = client.stream_chat_completion(messages: messages, tools: tools)
      expect(usage).to be_nil
    end
  end
end
