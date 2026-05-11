# frozen_string_literal: true

require "rails_helper"

RSpec.describe AiUsage, type: :model do
  let(:user) { create(:user, role: :client) }

  describe "ROLE_LIMITS" do
    it "matches locked role quotas" do
      expect(described_class::ROLE_LIMITS).to eq(
        "client" => 10_000,
        "admin" => 50_000
      )
      expect(described_class::ROLE_LIMITS).to be_frozen
    end
  end

  describe ".charge!" do
    it "returns cumulative token usage across calls" do
      expect(described_class.charge!(user, input_tokens: 50, output_tokens: 50)).to eq(100)
      expect(described_class.charge!(user, input_tokens: 25, output_tokens: 25)).to eq(150)
    end

    it "raises QuotaExceededError with post-update totals" do
      described_class.create!(user: user, usage_date: Date.current, tokens_used: 9_900)

      expect do
        described_class.charge!(user, input_tokens: 200, output_tokens: 0)
      end.to raise_error(AiUsage::QuotaExceededError) { |err|
        expect(err.tokens_used).to eq(10_100)
        expect(err.limit).to eq(10_000)
      }
    end

    it "emits additive upsert sql with returning" do
      captured_sql = []
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        sql = payload[:sql]
        captured_sql << sql if sql.include?("ai_usages")
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        described_class.charge!(user, input_tokens: 10, output_tokens: 5)
      end

      merged = captured_sql.join(" ")
      expect(merged).to include("INSERT INTO")
      expect(merged).to include("ON CONFLICT")
      expect(merged).to include("DO UPDATE")
      expect(merged).to include("ai_usages.tokens_used + EXCLUDED.tokens_used")
      expect(merged).to include("RETURNING")
      expect(merged).to include("tokens_used")
    end
  end

  describe ".current_total" do
    it "returns 0 for a new user and current usage after charge" do
      expect(described_class.current_total(user)).to eq(0)
      described_class.charge!(user, input_tokens: 10, output_tokens: 20)
      expect(described_class.current_total(user)).to eq(30)
    end
  end

  describe ".refuse_if_exceeded!" do
    it "raises only when usage is at or over limit" do
      expect(described_class.refuse_if_exceeded!(user)).to eq(0)

      described_class.where(user: user, usage_date: Date.current).update_all(tokens_used: 10_000)

      expect do
        described_class.refuse_if_exceeded!(user)
      end.to raise_error(AiUsage::QuotaExceededError)
    end
  end

  describe "concurrent load", :concurrent do
    it "never overshoots the client limit under four racing writers" do
      expect(ActiveRecord::Base.connection_pool.size).to be >= 5

      concurrency_level = 4
      delta_per_call = 100
      calls_per_thread = 30
      gate = true

      threads = concurrency_level.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            true while gate

            calls_per_thread.times do
              begin
                described_class.charge!(user, input_tokens: delta_per_call, output_tokens: 0)
              rescue AiUsage::QuotaExceededError
                nil
              end
            end
          end
        end
      end

      gate = false
      threads.each(&:join)

      final_total = described_class.current_total(user)
      expect(final_total).to be <= AiUsage::ROLE_LIMITS["client"]
    ensure
      ActiveRecord::Base.connection_pool.disconnect!
    end
  end
end
