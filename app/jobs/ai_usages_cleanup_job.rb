# frozen_string_literal: true

class AiUsagesCleanupJob < ApplicationJob
  queue_as :default

  RETENTION_DAYS = 90

  def perform
    threshold = RETENTION_DAYS.days.ago.to_date
    deleted = AiUsage.where("usage_date < ?", threshold).delete_all
    Rails.logger.info "[AiUsagesCleanup] deleted #{deleted} rows older than #{threshold}" if deleted.positive?
  end
end
