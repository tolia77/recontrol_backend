# frozen_string_literal: true

require "securerandom"

class AssistantChannel < ApplicationCable::Channel
  # Per AGENT-08: operator-selectable model from a fixed allowlist. Phase 18 reads from the
  # OpenRouterClient constant (Plan 3 lands the constant); during Plan 1 the constant is
  # not yet defined -- guard with a const_defined? check so this channel can be loaded
  # before OpenRouterClient exists. Plan 3 removes the guard.
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

    @session_token = SecureRandom.uuid

    # NOTE: Plan 5 replaces this transmit with `@agent_runner = AgentRunner.new(...)` and
    # `@agent_thread = Thread.new { @agent_runner.run }`. Plan 1 just confirms the session
    # bind for early integration tests.
    transmit({ type: "accepted", session_token: @session_token, model: model })
  end

  def stop_loop(_data = {})
    # Plan 5 wires this to @agent_runner.request_stop. Nil-safe in Plan 1 so spec passes
    # before AgentRunner exists.
    @agent_runner&.request_stop
  end

  def unsubscribed
    # AGENT-11: kill the agent thread within 1 second and let the ensure-block emit the
    # terminating done/error broadcast (STREAM-06).
    @agent_thread&.kill
    joined = @agent_thread&.join(1.0)
    Rails.logger.warn "[AssistantChannel] unsubscribed timeout (thread did not unwind in 1s)" if @agent_thread && joined.nil?
    # TODO Phase 19: ai_usages.commit(@partial_tokens)
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
    if defined?(OpenRouterClient) && OpenRouterClient.const_defined?(:DEFAULT_MODEL)
      OpenRouterClient::DEFAULT_MODEL
    else
      ENV.fetch("OPENROUTER_MODEL", "anthropic/claude-3.5-sonnet")
    end
  end

  def allowed_models
    if defined?(OpenRouterClient) && OpenRouterClient.const_defined?(:ALLOWED_MODELS)
      OpenRouterClient::ALLOWED_MODELS
    else
      # Plan 1 fallback when OpenRouterClient does not exist yet. Plan 3 retires this branch.
      [ENV.fetch("OPENROUTER_MODEL", "anthropic/claude-3.5-sonnet")].freeze
    end
  end
end
