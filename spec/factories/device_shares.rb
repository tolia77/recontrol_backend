FactoryBot.define do
  factory :device_share do
    device
    user
    permissions_group
    status { "active" }
    expires_at { 7.days.from_now }
  end
end
