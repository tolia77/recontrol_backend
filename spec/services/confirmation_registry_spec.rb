# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfirmationRegistry do
  after { described_class::REGISTRY.clear }

  describe ".register / .fetch / .delete" do
    it "returns a Queue and stores it under the confirmation_id" do
      cid = SecureRandom.uuid
      q = described_class.register(cid)
      expect(q).to be_a(Queue)
      expect(described_class.fetch(cid)).to be(q)
    end

    it "fetch returns nil for unknown id" do
      expect(described_class.fetch("does-not-exist")).to be_nil
    end

    it "delete removes the entry" do
      cid = SecureRandom.uuid
      described_class.register(cid)
      described_class.delete(cid)
      expect(described_class.fetch(cid)).to be_nil
    end
  end

  describe ".deliver" do
    it "pushes onto the registered Queue (operator allow)" do
      cid = SecureRandom.uuid
      q = described_class.register(cid)
      described_class.deliver(cid, { decision: "allow" })
      expect(q.pop(true)).to eq({ decision: "allow" })
    end

    it "pushes onto the registered Queue (operator deny)" do
      cid = SecureRandom.uuid
      q = described_class.register(cid)
      described_class.deliver(cid, { decision: "deny" })
      expect(q.pop(true)).to eq({ decision: "deny" })
    end

    it "is a silent no-op for missing/expired ids" do
      expect { described_class.deliver("missing", { decision: "allow" }) }.not_to raise_error
    end

    it "is a silent no-op when the queue is closed" do
      cid = SecureRandom.uuid
      q = described_class.register(cid)
      q.close
      expect { described_class.deliver(cid, { decision: "allow" }) }.not_to raise_error
    end
  end

  describe "thread safety" do
    it "register from 100 concurrent threads stores all entries" do
      cids = 100.times.map { SecureRandom.uuid }
      threads = cids.map { |c| Thread.new { described_class.register(c) } }
      threads.each(&:join)
      expect(cids.all? { |c| described_class.fetch(c).is_a?(Queue) }).to be true
    end
  end

  describe ".size" do
    it "reflects the current map cardinality" do
      before_size = described_class.size
      cid = SecureRandom.uuid
      described_class.register(cid)
      expect(described_class.size).to eq(before_size + 1)
      described_class.delete(cid)
      expect(described_class.size).to eq(before_size)
    end
  end
end
