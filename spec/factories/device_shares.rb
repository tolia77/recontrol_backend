FactoryBot.define do
  factory :device_share do
    device { nil }
    user { nil }
    permissions_group { nil }
    status { "MyString" }
    expires_at { "2025-11-05 00:20:55" }
  end
end
