# frozen_string_literal: true

FactoryBot.define do
  factory :ai_session do
    association :user
    device { association(:device, user: user) }
    started_at { 1.minute.ago }
    ended_at { Time.current }
    turn_count { 1 }
    input_tokens { 50 }
    output_tokens { 50 }
    model { "anthropic/claude-3.5-sonnet" }
    stop_reason { "completed" }
  end
end
