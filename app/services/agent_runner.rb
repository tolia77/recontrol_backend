# frozen_string_literal: true

require "concurrent"
require "json"
require "securerandom"

# AgentRunner
# -----------
# In-process Thread driver for the multi-turn agent loop. Spawned by
# AssistantChannel#run_prompt; lives until completion, error, any of the four
# loop-control caps, or AssistantChannel#unsubscribed (Thread#kill + 1.0s join).
#
# Owns:
#   - The four loop-control caps (MAX_TURNS, WALL_CLOCK_SECONDS,
#     loop-detector triple, user-stop AtomicBoolean)
#   - The token flush timer (Concurrent::TimerTask @ FLUSH_INTERVAL_SECONDS)
#   - The seq counter (Mutex-guarded; STREAM-02)
#   - The session_token (per-prompt UUID; STREAM-04)
#   - The TOOL-05 rolling history (HISTORY_BYTE_CAP byte cap)
#   - The ensure-block fail-safe terminator (STREAM-06)
#
# Broadcasts ONLY these five envelope types in Phase 18:
#   token | tool_call_start | tool_call_result | done | error
# The two reserved types (requires_confirmation, quota_warning) are Phase 19.
#
# Logging contract: never log prompt content, tool output, message body, or
# the API key. Lines carry only the [AgentRunner] tag + exception class.
class AgentRunner
  # ──────────────────────────────────────────────────────────────────────────
  # Loop-control caps (single source of truth)
  # ──────────────────────────────────────────────────────────────────────────
  MAX_TURNS              = 25     # AGENT-04
  WALL_CLOCK_SECONDS     = 120    # AGENT-05; must match OpenRouterClient::READ_TIMEOUT_S
  FLUSH_INTERVAL_SECONDS = 0.075  # STREAM-05; mid-range of the 50-100 ms window (D-05)
  HISTORY_BYTE_CAP       = 4_096  # TOOL-05; last 4 KB of rolling stdout/stderr

  # ──────────────────────────────────────────────────────────────────────────
  # Stop reason codes (for `done` broadcast envelope)
  # ──────────────────────────────────────────────────────────────────────────
  STOP_REASONS = %w[completed max_turns wall_clock loop_detected user_stopped].freeze

  attr_reader :session_token

  def initialize(user:, device:, prompt:, model:, session_token:, openrouter_client: nil)
    @user           = user
    @device         = device
    @prompt         = prompt.to_s
    @model          = model
    @session_token  = session_token

    @client         = openrouter_client || OpenRouterClient.new(model: model)

    @seq            = 0
    @seq_mutex      = Mutex.new

    @flush_buffer   = []
    @flush_mutex    = Mutex.new
    @flush_timer    = build_flush_timer

    @stop_flag      = Concurrent::AtomicBoolean.new(false)
    @last_tool_call_triple = nil  # AGENT-06; populated only after run_command dispatches

    # TOOL-05: rolling history of recent tool_call_result text content for grounding.
    @history_text   = +""

    @terminated     = false  # STREAM-06; flipped by broadcast_done / broadcast_error

    @messages = [
      { role: "system", content: OpenRouterClient::SYSTEM_PROMPT_TEMPLATE },
      { role: "user",   content: @prompt }
    ]
  end

  # AGENT-07: cooperative stop. Loop checks at turn boundaries.
  def request_stop
    @stop_flag.make_true
  end

  # AGENT-11 helper: AssistantChannel#unsubscribed already calls Thread#kill +
  # join(1.0); we expose this for symmetry / spec readability.
  def stop_flag_set?
    @stop_flag.true?
  end

  # ──────────────────────────────────────────────────────────────────────────
  # The main loop. Spawned in a Thread by AssistantChannel#run_prompt.
  # ──────────────────────────────────────────────────────────────────────────
  def run
    started_monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    turn_count = 0

    @flush_timer.execute

    loop do
      # AGENT-07 / AGENT-05 / AGENT-04 turn-boundary checks
      return broadcast_done(:user_stopped) if @stop_flag.true?
      if (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_monotonic) > WALL_CLOCK_SECONDS
        return broadcast_done(:wall_clock)
      end
      if turn_count >= MAX_TURNS
        attempt_wrap_up_turn
        return broadcast_done(:max_turns)
      end

      # AGENT-02 / AGENT-09: call OpenRouter with the running message history.
      finish_reason, assistant_msg = @client.stream_chat_completion(
        messages: @messages,
        tools:    AiTools.all_definitions,
        model:    @model
      ) do |type, payload|
        push_token_to_buffer(payload) if type == :token
      end

      @messages << assistant_msg

      if finish_reason == "tool_calls"
        handled = handle_tool_calls(assistant_msg["tool_calls"])
        return if handled == :loop_detected  # broadcast already sent
        turn_count += 1
        # Continue loop -- next iteration calls OpenRouter again with appended tool results.
      else
        # finish_reason in {"stop", "length", "content_filter"} -- non-tool final.
        return broadcast_done(:completed)
      end
    end
  rescue OpenRouterClient::OpenRouterError => e
    Rails.logger.warn "[AgentRunner] openrouter error: #{e.class}"
    broadcast_error(source: "openrouter", message: e.message)
  rescue ArgumentError => e
    # Unknown tool name / illegal argument from AiTools.fetch.
    Rails.logger.warn "[AgentRunner] argument error: #{e.class}"
    broadcast_error(source: "internal", message: e.message)
  rescue StandardError => e
    Rails.logger.error "[AgentRunner] unexpected: #{e.class}"
    broadcast_error(source: "internal", message: "internal_error")
  ensure
    # STREAM-05 final flush: drain any tokens left in the buffer.
    flush_tokens
    @flush_timer&.shutdown
    # STREAM-06 fail-safe terminator: if the loop somehow exited without calling
    # broadcast_done / broadcast_error (e.g. Thread#kill before any rescue ran),
    # emit one ourselves so the frontend never sees a frozen spinner.
    unless @terminated
      emit(type: "error", source: "internal", message: "agent thread exited unexpectedly")
      @terminated = true
    end
  end

  private

  # ──────────────────────────────────────────────────────────────────────────
  # Flush timer (STREAM-05 / D-05 / RF-6)
  # ──────────────────────────────────────────────────────────────────────────
  def build_flush_timer
    Concurrent::TimerTask.new(execution_interval: FLUSH_INTERVAL_SECONDS) do
      flush_tokens
    rescue StandardError => e
      Rails.logger.warn "[AgentRunner] flush error: #{e.class}"
    end
  end

  def push_token_to_buffer(token_str)
    @flush_mutex.synchronize { @flush_buffer << token_str }
  end

  # STREAM-05: batch tokens in 20-50/50-100ms cadence. Rationale (per RESEARCH §RF-8):
  # DB row pressure (Solid Cable writes one row per broadcast) + frontend rendering
  # smoothness; NOT the legacy 8 KB PG NOTIFY adapter limit.
  def flush_tokens
    joined = @flush_mutex.synchronize do
      next "" if @flush_buffer.empty?
      tokens = @flush_buffer.dup
      @flush_buffer.clear
      tokens.join
    end
    return if joined.empty?
    emit(type: "token", content: joined)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Tool-call handling (AGENT-02 / AGENT-06 / D-08)
  # ──────────────────────────────────────────────────────────────────────────
  def handle_tool_calls(tool_calls)
    # D-08: sequential dispatch within a single assistant turn.
    Array(tool_calls).each do |tc|
      name         = tc.dig("function", "name")
      tool_call_id = tc["id"] || SecureRandom.uuid  # defensive; OpenRouter always sends id
      args_json    = tc.dig("function", "arguments")
      args         = parse_arguments(args_json)

      # AGENT-06 loop-detector (only meaningful for run_command):
      if name == "run_command" && args.is_a?(Hash)
        triple = [args[:binary] || args["binary"], args[:args] || args["args"], args[:cwd] || args["cwd"]]
        if triple == @last_tool_call_triple
          broadcast_done(:loop_detected, message: "Agent appears stuck -- try rephrasing")
          return :loop_detected
        end
        @last_tool_call_triple = triple
      end

      tool_klass = begin
        AiTools.fetch(name)
      rescue ArgumentError
        nil
      end

      if tool_klass.nil?
        result = { error: "unknown_tool", name: name }
        emit(type: "tool_call_start", name: name, label: name, args: args, tool_call_id: tool_call_id)
        emit(type: "tool_call_result", name: name, tool_call_id: tool_call_id, result: result)
        append_tool_message(tool_call_id, result)
        next
      end

      # STREAM-07: broadcast the start with HUMAN_LABEL + structured args.
      emit(type: "tool_call_start",
           name: name, label: tool_klass::HUMAN_LABEL,
           args: args, tool_call_id: tool_call_id)

      result = tool_klass.new(device: @device).call(args.is_a?(Hash) ? args.transform_keys(&:to_sym) : {})

      # STREAM-07: broadcast the result envelope; raw OpenRouter JSON never broadcast.
      emit(type: "tool_call_result",
           name: name, tool_call_id: tool_call_id, result: result)

      # TOOL-05: append textual content from this tool result to the rolling history.
      append_to_history(result)

      # AGENT-02: feed result back into the message stream as role: "tool".
      append_tool_message(tool_call_id, result)
    end
    :ok
  end

  def append_tool_message(tool_call_id, result)
    @messages << {
      role: "tool",
      tool_call_id: tool_call_id,
      # RF-3: content is a STRING (JSON-serialized) -- the LLM expects a string body.
      content: result.to_json
    }
  end

  def parse_arguments(args_json)
    return {} if args_json.nil? || args_json.empty?
    JSON.parse(args_json, symbolize_names: false)
  rescue JSON::ParserError
    {}  # AgentRunner passes the empty hash to AiTools::Base#call which returns invalid_arguments.
  end

  # TOOL-05 rolling history: keep only the last HISTORY_BYTE_CAP bytes of concatenated
  # stdout/stderr text so the LLM sees a bounded grounding window. Phase 19 may refine.
  def append_to_history(result)
    return unless result.is_a?(Hash)
    text_parts = []
    stdout = result[:stdout] || result["stdout"]
    stderr = result[:stderr] || result["stderr"]
    text_parts << stdout if stdout.is_a?(String)
    text_parts << stderr if stderr.is_a?(String)
    return if text_parts.empty?
    @history_text << "\n#{text_parts.join("\n")}"
    if @history_text.bytesize > HISTORY_BYTE_CAP
      # Trim from the LEFT; keep most recent text.
      excess = @history_text.bytesize - HISTORY_BYTE_CAP
      @history_text = +(@history_text.byteslice(excess, @history_text.bytesize - excess) || "")
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # AGENT-04 wrap-up turn (best-effort; failure does not block max_turns broadcast)
  # ──────────────────────────────────────────────────────────────────────────
  def attempt_wrap_up_turn
    wrap_up_msgs = @messages + [{ role: "user", content: "You have reached the 25-turn cap. Briefly synthesize what you found in 1-2 sentences." }]
    @client.stream_chat_completion(messages: wrap_up_msgs, tools: [], model: @model) do |type, payload|
      push_token_to_buffer(payload) if type == :token
    end
    flush_tokens
  rescue StandardError => e
    Rails.logger.warn "[AgentRunner] wrap-up turn failed: #{e.class}"
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Broadcast helpers (STREAM-02 / STREAM-03 / STREAM-04 / STREAM-06)
  # ──────────────────────────────────────────────────────────────────────────
  def stream_name
    "assistant_#{@user.id}_to_#{@device.id}"
  end

  def next_seq
    @seq_mutex.synchronize { @seq += 1 }
  end

  def emit(payload)
    # STREAM-02 / STREAM-04: seq + session_token attach BEFORE broadcast (anti-race).
    envelope = {
      seq: next_seq,
      session_token: @session_token
    }.merge(payload)
    ActionCable.server.broadcast(stream_name, envelope)
  end

  def broadcast_done(reason, **extra)
    flush_tokens  # ensure no tokens trail the done envelope
    emit({ type: "done", stop_reason: reason.to_s }.merge(extra))
    @terminated = true
  end

  def broadcast_error(source:, message:)
    flush_tokens
    emit(type: "error", source: source, message: message)
    @terminated = true
  end
end
