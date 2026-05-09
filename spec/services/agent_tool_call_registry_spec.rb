# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentToolCallRegistry do
  # Each example starts with a clean registry. The registry is process-global so
  # we explicitly clean up registered ids in `after`. We do NOT instance-variable
  # access REGISTRY directly in tests (encapsulation).
  let(:tool_call_id) { SecureRandom.uuid }

  after { described_class.delete(tool_call_id) }

  describe ".register" do
    it "returns a Queue and stores it under the tool_call_id" do
      queue = described_class.register(tool_call_id)
      expect(queue).to be_a(Queue)
      expect(described_class.fetch(tool_call_id)).to equal(queue)
    end
  end

  describe ".fetch" do
    it "returns nil for an unknown id (does not raise)" do
      expect(described_class.fetch("does-not-exist-#{SecureRandom.uuid}")).to be_nil
    end
  end

  describe ".delete" do
    it "removes the entry; subsequent fetch returns nil" do
      described_class.register(tool_call_id)
      described_class.delete(tool_call_id)
      expect(described_class.fetch(tool_call_id)).to be_nil
    end
  end

  describe "concurrency soak" do
    it "does not leak entries when 50 threads register-then-delete" do
      start_size = described_class.size
      threads = 50.times.map do
        Thread.new do
          id = SecureRandom.uuid
          described_class.register(id)
          described_class.delete(id)
        end
      end
      threads.each(&:join)
      expect(described_class.size).to eq(start_size)
    end

    it "isolates per-id queues across two concurrent registrations" do
      id_a = "a-#{SecureRandom.uuid}"
      id_b = "b-#{SecureRandom.uuid}"
      q_a = described_class.register(id_a)
      q_b = described_class.register(id_b)
      q_a.push(:value_a)
      expect(described_class.fetch(id_b)).to equal(q_b)
      expect(described_class.fetch(id_b).empty?).to be true
      described_class.delete(id_a)
      described_class.delete(id_b)
    end
  end
end
