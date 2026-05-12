class Device < ApplicationRecord
  belongs_to :user, required: true
  has_many :device_shares, dependent: :destroy
  has_many :sessions, dependent: :destroy
  validates :name, presence: true, length: { minimum: 1, maximum: 32 }
  # Only "active" and "inactive" are persisted. "used" is a derived API value
  # projected by #status when a web client is currently connected; it is never
  # written to the column. Validation accepts it for backward-compat with any
  # rows that may still hold the legacy value.
  validates :status, presence: true, inclusion: { in: %w[active used inactive] }
  attribute :status, default: "inactive"

  # Override the status reader so callers (serializer, as_json, controllers)
  # see "used" when a live web client is currently controlling this device.
  # Backed by a TTL'd cache entry that the web client refreshes via heartbeat
  # messages. If the browser dies for any reason, the heartbeat stops and the
  # entry expires within WEB_PRESENCE_TTL — no event handler required, so
  # ungraceful WebSocket closes (tab killed, network drop, VPN flap) cannot
  # leave the status stuck. Per-process cache; with one Puma worker this is
  # exact. With multiple workers, switch Rails.cache to a shared backend
  # (solid_cache or Redis).
  WEB_PRESENCE_TTL = 45.seconds

  def status
    raw = super
    return "used" if raw == "active" && self.class.web_present?(id)
    raw
  end

  def self.web_presence_key(device_id)
    "device:#{device_id}:web_present"
  end

  def self.mark_web_present(device_id)
    Rails.cache.write(web_presence_key(device_id), true, expires_in: WEB_PRESENCE_TTL)
  end

  def self.web_present?(device_id)
    Rails.cache.exist?(web_presence_key(device_id))
  end
end
