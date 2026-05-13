# frozen_string_literal: true

module CommandBridge
  module_function

  # TOOL-07: 15-second per-tool-call timeout. Native Queue#pop(timeout:) returns nil
  # on timeout (Ruby >= 3.2 keyword form, RESEARCH §RF-2). Do NOT wrap with the
  # stdlib async-exception based timeout helper -- it injects exceptions into ensure blocks.
  TOOL_CALL_TIMEOUT_SECONDS = 15

  # AgentRunner / AiTools::Base#call invoke this. Returns either the desktop's
  # parsed response hash or `{ error: "tool_timeout" }`. Never raises on timeout.
  #
  # D-06 / D-07: tool_call_id MUST be a fresh SecureRandom.uuid per call -- the
  # caller (AiTools::Base) generates it and passes it in. On the desktop wire
  # the same value is sent as `id` (the existing request/response correlation
  # field used by every other command); the name `tool_call_id` only lives in
  # backend-internal code and in frontend-facing broadcasts (where it carries
  # the model's OpenRouter tool_call id semantics).
  # D-09: on return-or-timeout, the registry entry is deleted in the ensure block.
  def dispatch(device:, payload:, tool_call_id:)
    queue = AgentToolCallRegistry.register(tool_call_id)

    ActionCable.server.broadcast(
      "device_#{device.id}",
      payload.merge(id: tool_call_id)
    )

    result = queue.pop(timeout: TOOL_CALL_TIMEOUT_SECONDS)
    result || { error: "tool_timeout" }
  ensure
    AgentToolCallRegistry.delete(tool_call_id)
  end

  # Called by CommandChannel#handle_desktop_message when an inbound desktop
  # response's `id` is in our pending registry. Late responses (after timeout-
  # driven registry cleanup) are silently discarded with a forensic warn-log.
  def deliver(tool_call_id, result)
    queue = AgentToolCallRegistry.fetch(tool_call_id)
    unless queue
      Rails.logger.warn "[CommandBridge] late response for #{tool_call_id}"
      return
    end
    queue.push(result)
  rescue ClosedQueueError => e
    # Defensive: should not happen under documented usage, but log if it ever does.
    Rails.logger.warn "[CommandBridge] closed queue for #{tool_call_id}: #{e.class}"
  end

  # CommandChannel uses this to disambiguate AI-tool responses from legacy
  # operator broadcasts: both share the desktop response shape (`{id, status,
  # result}`), so the router checks whether the inbound id matches an
  # outstanding AgentRunner call before deciding where to send it.
  def has_pending?(id)
    return false if id.nil? || id.empty?
    !AgentToolCallRegistry.fetch(id).nil?
  end
end
