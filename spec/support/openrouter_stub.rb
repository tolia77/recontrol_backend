# frozen_string_literal: true

# OpenRouterStub
# --------------
# Minimal SSE response fixtures for OpenRouterClient specs. The stream shapes
# follow OpenRouter / OpenAI streaming contract per RESEARCH RF-3:
#
#   - data lines: `data: <json>\n\n`
#   - end-of-stream sentinel: `data: [DONE]\n\n` (application-level, not
#     SSE-spec; the parser yields it as a normal event with data == "[DONE]")
#   - heartbeat comments: `: OPENROUTER PROCESSING\n\n` (SSE comments;
#     event_stream_parser silently ignores them)
#   - tool_calls are streamed INDEX-keyed (not id-keyed); function.arguments
#     is concatenated across multiple chunks at the same index, with `id` and
#     `function.name` arriving only on the first chunk for that index
module OpenRouterStub
  module_function

  # Build a single SSE data line: `data: <json>\n\n`
  def data_line(payload)
    "data: #{payload.to_json}\n\n"
  end

  def done_line
    "data: [DONE]\n\n"
  end

  def heartbeat_line
    ": OPENROUTER PROCESSING\n\n"
  end

  # Token text response, terminated with finish_reason: "stop" + [DONE].
  def token_stream(fragments: %w[Hello there world], finish_reason: "stop")
    lines = []
    fragments.each do |frag|
      lines << data_line(
        "choices" => [{ "index" => 0, "delta" => { "content" => frag } }]
      )
    end
    lines << data_line(
      "choices" => [{ "index" => 0, "delta" => {}, "finish_reason" => finish_reason }]
    )
    lines << done_line
    lines.join
  end

  # Single tool_call whose function.arguments JSON is split across `chunks`
  # deltas at the same index. Only the first chunk carries `id` +
  # `function.name`; subsequent chunks carry only `function.arguments` slices.
  # Verifies RF-3's index-keyed accumulator across multi-chunk reconstruction.
  def split_tool_call_stream(name:, arguments_json:, chunks: 5, id: "call_x", finish_reason: "tool_calls")
    lines = []
    slice_size = (arguments_json.length / chunks.to_f).ceil
    slices = arguments_json.chars.each_slice(slice_size).map(&:join)
    slices.each_with_index do |slice, i|
      tc = { "index" => 0 }
      if i.zero?
        tc["id"]       = id
        tc["type"]     = "function"
        tc["function"] = { "name" => name, "arguments" => slice }
      else
        tc["function"] = { "arguments" => slice }
      end
      lines << data_line(
        "choices" => [{ "index" => 0, "delta" => { "tool_calls" => [tc] } }]
      )
    end
    lines << data_line(
      "choices" => [{ "index" => 0, "delta" => {}, "finish_reason" => finish_reason }]
    )
    lines << done_line
    lines.join
  end

  # Two parallel tool_calls at index 0 and 1; each one chunk for simplicity.
  def two_tool_call_stream
    data_line(
      "choices" => [{ "index" => 0, "delta" => { "tool_calls" => [
        { "index" => 0, "id" => "call_a", "type" => "function",
          "function" => { "name" => "run_command", "arguments" => '{"binary":"ls","args":[],"cwd":"/tmp"}' } },
        { "index" => 1, "id" => "call_b", "type" => "function",
          "function" => { "name" => "list_processes", "arguments" => "{}" } }
      ] } }]
    ) +
      data_line(
        "choices" => [{ "index" => 0, "delta" => {}, "finish_reason" => "tool_calls" }]
      ) +
      done_line
  end

  # Mid-stream error envelope (AGENT-10 / RF-3): HTTP 200 + finish_reason "error".
  def mid_stream_error_stream(message: "upstream model timed out")
    data_line(
      "id" => "x", "object" => "chat.completion.chunk",
      "error" => { "code" => "model_timeout", "message" => message },
      "choices" => [{ "index" => 0, "delta" => { "content" => "" }, "finish_reason" => "error" }]
    ) + done_line
  end
end
