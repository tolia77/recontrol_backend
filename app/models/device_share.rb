class DeviceShare < ApplicationRecord
  belongs_to :device
  belongs_to :user
  belongs_to :permissions_group
end
