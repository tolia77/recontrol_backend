FactoryBot.define do
  factory :session do
    association :user
    device { nil }
    client_type { "web" }
    status { "active" }
    # jti, session_key, and expires_at are set by model callbacks

    trait :desktop do
      client_type { "desktop" }
      after(:build) do |session|
        session.device ||= build(:device, user: session.user)
      end
    end

    trait :revoked do
      status { "revoked" }
    end
  end
end
