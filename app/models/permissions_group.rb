class PermissionsGroup < ApplicationRecord
  belongs_to :user

  # Ensure all permission booleans are false by default
  attribute :see_screen, :boolean, default: false
  attribute :see_system_info, :boolean, default: false
  attribute :access_mouse, :boolean, default: false
  attribute :access_keyboard, :boolean, default: false
  attribute :access_terminal, :boolean, default: false
  attribute :manage_power, :boolean, default: false
end
