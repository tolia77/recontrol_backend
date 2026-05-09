# frozen_string_literal: true

module AgentToolCallRegistry
  module_function

  # Process-global registry keyed by tool_call_id UUID. Values are per-call Queue
  # instances. CommandBridge#dispatch writes a Queue here, broadcasts to the desktop,
  # and blocks on `Queue#pop(timeout: 15)`. CommandBridge#deliver looks up the Queue
  # by tool_call_id and pushes the desktop's response onto it.
  #
  # D-06: Concurrent::Map provides lock-free reads and stronger happens-before
  #       guarantees than Mutex+Hash; concurrent-ruby 1.3.5 ships it (Gemfile.lock:93).
  # D-09: A nil return from #fetch is the canonical "this id was already cleaned up
  #       (timeout fired or duplicate response)" signal -- callers `|| return`.
  REGISTRY = Concurrent::Map.new

  def register(tool_call_id)
    queue = Queue.new
    REGISTRY[tool_call_id] = queue
    queue
  end

  def fetch(tool_call_id)
    REGISTRY[tool_call_id]
  end

  def delete(tool_call_id)
    REGISTRY.delete(tool_call_id)
  end

  def size
    REGISTRY.size
  end
end
