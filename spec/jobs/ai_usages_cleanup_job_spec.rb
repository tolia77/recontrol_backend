# frozen_string_literal: true

require "rails_helper"

RSpec.describe AiUsagesCleanupJob, type: :job do
  let(:user) { create(:user) }

  it "deletes ai_usages rows older than 90 days, keeps newer rows" do
    old_row = AiUsage.create!(user: user, usage_date: 91.days.ago.to_date, tokens_used: 500)
    edge_row = AiUsage.create!(user: user, usage_date: 89.days.ago.to_date, tokens_used: 500)
    fresh_row = AiUsage.create!(user: user, usage_date: Date.current, tokens_used: 100)

    expect { described_class.new.perform }.to change(AiUsage, :count).by(-1)

    expect { old_row.reload }.to raise_error(ActiveRecord::RecordNotFound)
    expect(edge_row.reload).to be_present
    expect(fresh_row.reload).to be_present
  end

  it "exposes RETENTION_DAYS = 90" do
    expect(described_class::RETENTION_DAYS).to eq(90)
  end
end
