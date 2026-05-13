# frozen_string_literal: true

require "rails_helper"

RSpec.describe AiSession, type: :model do
  let(:user) { create(:user) }
  let(:device) { create(:device, user: user) }

  describe "associations" do
    it "belongs_to :user" do
      assoc = described_class.reflect_on_association(:user)
      expect(assoc.macro).to eq(:belongs_to)
    end

    it "belongs_to :device, optional: true" do
      assoc = described_class.reflect_on_association(:device)
      expect(assoc.macro).to eq(:belongs_to)
      expect(assoc.options[:optional]).to be true
    end
  end

  describe "validations" do
    it "requires started_at" do
      session = described_class.new(user: user, device: device, started_at: nil, model: "x")
      expect(session).not_to be_valid
      expect(session.errors[:started_at]).to be_present
    end

    it "requires model" do
      session = described_class.new(user: user, device: device, started_at: Time.current, model: nil)
      expect(session).not_to be_valid
      expect(session.errors[:model]).to be_present
    end

    it "rejects unknown stop_reason values" do
      session = described_class.new(user: user, device: device, started_at: Time.current, model: "x", stop_reason: "bogus")
      expect(session).not_to be_valid
      expect(session.errors[:stop_reason]).to be_present
    end

    it "allows nil stop_reason (in-flight session)" do
      session = described_class.new(user: user, device: device, started_at: Time.current, model: "x", stop_reason: nil)
      expect(session).to be_valid
    end

    %w[completed max_turns wall_clock loop_detected user_stopped tab_closed quota orphaned error].each do |reason|
      it "accepts stop_reason=#{reason}" do
        session = described_class.new(user: user, device: device, started_at: Time.current, model: "x", stop_reason: reason)
        expect(session).to be_valid
      end
    end
  end

  describe "STOP_REASONS constant" do
    it "exposes the frozen locked list including orphaned" do
      expect(described_class::STOP_REASONS).to be_frozen
      expect(described_class::STOP_REASONS).to contain_exactly(
        "completed", "max_turns", "wall_clock", "loop_detected",
        "user_stopped", "tab_closed", "quota", "orphaned", "error"
      )
    end
  end

  describe "AUDIT-03: on device deletion the row survives with device_id=NULL" do
    it "nulls out device_id when the device is destroyed" do
      session = described_class.create!(user: user, device: device,
                                        started_at: Time.current, model: "anthropic/claude-sonnet-4.6")

      device.destroy!
      session.reload

      expect(session.device_id).to be_nil
      expect(session).to be_persisted
    end
  end
end
