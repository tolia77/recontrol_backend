class Device < ApplicationRecord
  belongs_to :user, required: true
  validates :name, presence: true, length: { minimum: 1, maximum: 32 }
  validates :status, presence: true, inclusion: { in: %w(active inactive) }
  attribute :status, default: "inactive"
end
