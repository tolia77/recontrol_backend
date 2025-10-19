FactoryBot.define do
  factory :device do
    association :user
    sequence(:name) { |n| "Device #{n}" }
    status { "active" }
    last_active_at { Time.current }

    trait :inactive do
      status { "inactive" }
    end
  end
end
