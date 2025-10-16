class User < ApplicationRecord
  validates :username, uniqueness: true, presence: true, length: { minimum: 3, maximum: 20 }
  validates :email, uniqueness: true, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP, message: "Invalid email format" }
  validates :password, presence: true, length: { minimum: 8 }, on: :create
  enum :role, %i[client admin]
  attribute :role, default: 0
end
