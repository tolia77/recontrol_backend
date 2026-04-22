class SweepStaleDevicesJob < ApplicationJob
  queue_as :default

  STALE_AFTER = 60.seconds

  def perform
    threshold = STALE_AFTER.ago
    scope = Device.where(status: %w[active used])
                  .where("last_active_at IS NULL OR last_active_at < ?", threshold)
    updated = scope.update_all(status: "inactive")
    Rails.logger.info "[SweepStaleDevices] marked #{updated} devices inactive" if updated.positive?
  end
end
