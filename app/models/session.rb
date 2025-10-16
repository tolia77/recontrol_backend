class Session < ApplicationRecord
  belongs_to :user, required: true
  belongs_to :device
  before_create :set_initial_values
  enum :status, %i[active revoked]
  attribute :status, default: "active"
  private

  def set_initial_values
    self.jti ||= SecureRandom.uuid
    self.session_key ||= SecureRandom.uuid
    self.expires_at ||= ENV["JWT_REFRESH_EXPIRATION_DAYS"].to_i.days.from_now
  end
end
