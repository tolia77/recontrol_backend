class DeviceShare < ApplicationRecord
  belongs_to :device
  belongs_to :user
  belongs_to :permissions_group

  accepts_nested_attributes_for :permissions_group
end
