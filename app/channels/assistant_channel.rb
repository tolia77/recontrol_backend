# frozen_string_literal: true

require "securerandom"

class AssistantChannel < ApplicationCable::Channel
  # Per AGENT-08: operator-selectable model from a fixed allowlist. Plan 3 lands
  # OpenRouterClient with DEFAULT_MODEL + ALLOWED_MODELS; Plan 5 retires the
  # Plan-1 defined?-guarded fallback and references the constants directly.
  def subscribed
    unless valid_subscription?
      Rails.logger.warn "[AssistantChannel] Rejecting subscription: access denied for " \
                        "user_id=#{connection.current_user&.id} device_id=#{connection.target_device&.id}"
      reject
      return
    end

    stream_from assistant_stream(connection.current_user, connection.target_device)
  end

  def run_prompt(data)
    prompt = data["prompt"].to_s
    model  = (data["model"].presence || default_model)

    unless allowed_models.include?(model)
      transmit({ type: "error", message: "invalid_model", model: model })
      return
    end

    if prompt.strip.empty?
      transmit({ type: "error", message: "empty_prompt" })
      return
    end

    # Phase 20: honor a frontend-supplied session_token when it is UUID-shaped
    # so the reducer's STREAM-04 filter (transcriptReducer.ts) sees broadcasts
    # tagged with the same token it minted at submit time. Fall back to a fresh
    # SecureRandom.uuid for legacy callers (specs, older clients) that omit it.
    client_token = data["session_token"].to_s
    @session_token = uuid_v4_shape?(client_token) ? client_token : SecureRandom.uuid

    # AGENT-11 / STREAM-04: confirm acceptance BEFORE spawning the runner so the
    # frontend has the session_token in hand before any AgentRunner broadcast on
    # `assistant_<user>_to_<device>` could arrive.
    transmit({ type: "accepted", session_token: @session_token, model: model })

    @agent_runner = AgentRunner.new(
      user:          connection.current_user,
      device:        connection.target_device,
      prompt:        prompt,
      model:         model,
      session_token: @session_token
    )

    @agent_thread = Thread.new do
      @agent_runner.run
    rescue StandardError => e
      # AgentRunner's own rescue chain should have handled this; log defensively.
      Rails.logger.error "[AssistantChannel] runner thread escaped exception: #{e.class}"
    end
  end

  def stop_loop(_data = {})
    # Plan 5 wires this to @agent_runner.request_stop. Nil-safe in Plan 1 so spec passes
    # before AgentRunner exists.
    @agent_runner&.request_stop
  end

  def confirm_tool_call(data)
    confirmation_id = data["confirmation_id"].to_s
    decision = data["decision"].to_s

    unless %w[allow deny].include?(decision)
      Rails.logger.warn "[AssistantChannel] confirm_tool_call: invalid decision=#{decision}"
      return
    end

    ConfirmationRegistry.deliver(confirmation_id, { decision: decision })
  end

  def unsubscribed
    # AGENT-11: kill the agent thread within 1 second; AgentRunner's ensure block
    # emits the terminating done/error broadcast (STREAM-06) and finalizes the
    # AiSession row.
    @agent_thread&.kill
    joined = @agent_thread&.join(1.0)
    Rails.logger.warn "[AssistantChannel] unsubscribed timeout (thread did not unwind in 1s)" if @agent_thread && joined.nil?

    ai_session = @agent_runner&.ai_session
    if ai_session && ai_session.ended_at.nil?
      ai_session.update!(
        ended_at: Time.current,
        stop_reason: "tab_closed"
      )
    end
  end

  private

  def valid_subscription?
    device = connection.target_device
    user   = connection.current_user
    return false unless device && user

    # Owner-only gate for v1.4. The skeleton mirrors `CommandChannel#valid_web_subscription?`
    # so future shared-access widening is a one-line change.
    device.user_id == user.id
  end

  def assistant_stream(user, device)
    "assistant_#{user.id}_to_#{device.id}"
  end

  def default_model
    OpenRouterClient::DEFAULT_MODEL
  end

  def allowed_models
    OpenRouterClient::ALLOWED_MODELS
  end

  UUID_V4_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  def uuid_v4_shape?(value)
    value.is_a?(String) && value.match?(UUID_V4_RE)
  end
end
