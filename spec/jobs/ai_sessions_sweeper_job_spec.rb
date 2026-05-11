# frozen_string_literal: true

require "rails_helper"

RSpec.describe AiSessionsSweeperJob, type: :job do
  let(:user) { create(:user) }
  let(:device) { create(:device, user: user) }

  it "marks NULL-ended sessions older than 5 minutes as orphaned" do
    fresh_open = AiSession.create!(
      user: user,
      device: device,
      started_at: 2.minutes.ago,
      ended_at: nil,
      model: "anthropic/claude-3.5-sonnet"
    )
    stale_open = AiSession.create!(
      user: user,
      device: device,
      started_at: 10.minutes.ago,
      ended_at: nil,
      model: "anthropic/claude-3.5-sonnet"
    )
    closed = AiSession.create!(
      user: user,
      device: device,
      started_at: 10.minutes.ago,
      ended_at: 1.minute.ago,
      model: "anthropic/claude-3.5-sonnet",
      stop_reason: "completed"
    )

    described_class.new.perform

    expect(fresh_open.reload.ended_at).to be_nil
    expect(stale_open.reload.ended_at).to be_present
    expect(stale_open.stop_reason).to eq("orphaned")
    expect(closed.reload.stop_reason).to eq("completed")
  end

  it "exposes ORPHAN_AFTER = 5.minutes" do
    expect(described_class::ORPHAN_AFTER).to eq(5.minutes)
  end
end
