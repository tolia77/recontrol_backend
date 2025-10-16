FactoryBot.define do
  factory :session do
    user { nil }
    device { nil }
    jti { "MyString" }
    session_key { "MyString" }
    client_type { "MyString" }
    status { "MyString" }
    expires_at { "2025-10-16 19:42:49" }
  end
end
