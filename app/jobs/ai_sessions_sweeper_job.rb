# frozen_string_literal: true

class AiSessionsSweeperJob < ApplicationJob
  queue_as :default

  ORPHAN_AFTER = 5.minutes

  def perform
    threshold = ORPHAN_AFTER.ago
    scope = AiSession.where(ended_at: nil)
                     .where("started_at < ?", threshold)
    swept = scope.update_all(
      ended_at: Time.current,
      stop_reason: "orphaned",
      updated_at: Time.current
    )
    Rails.logger.warn "[AiSessionsSweeper] swept #{swept} orphaned sessions" if swept.positive?
  end
end
