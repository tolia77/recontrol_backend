class Device < ApplicationRecord
  belongs_to :user, required: true
  has_many :device_shares, dependent: :destroy
  has_many :sessions, dependent: :destroy
  validates :name, presence: true, length: { minimum: 1, maximum: 32 }
  validates :status, presence: true, inclusion: { in: %w(active inactive) }
  attribute :status, default: "inactive"
end
