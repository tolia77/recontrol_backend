# frozen_string_literal: true

module ConfirmationRegistry
  module_function

  REGISTRY = Concurrent::Map.new

  def register(confirmation_id)
    queue = Queue.new
    REGISTRY[confirmation_id] = queue
    queue
  end

  def fetch(confirmation_id)
    REGISTRY[confirmation_id]
  end

  def delete(confirmation_id)
    REGISTRY.delete(confirmation_id)
  end

  def deliver(confirmation_id, decision)
    queue = REGISTRY[confirmation_id]
    unless queue
      Rails.logger.warn "[ConfirmationRegistry] late/unknown confirmation_id #{confirmation_id}"
      return
    end

    queue.push(decision)
  rescue ClosedQueueError => e
    Rails.logger.warn "[ConfirmationRegistry] closed queue for #{confirmation_id}: #{e.class}"
  end

  def size
    REGISTRY.size
  end
end
