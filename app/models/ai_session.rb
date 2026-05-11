# frozen_string_literal: true

class AiSession < ApplicationRecord
  belongs_to :user
  belongs_to :device, optional: true

  validates :started_at, presence: true
  validates :model, presence: true

  STOP_REASONS = %w[
    completed max_turns wall_clock loop_detected
    user_stopped tab_closed quota orphaned error
  ].freeze
  validates :stop_reason, inclusion: { in: STOP_REASONS }, allow_nil: true
end
