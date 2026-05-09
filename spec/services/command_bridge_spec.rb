# frozen_string_literal: true

require "rails_helper"

RSpec.describe CommandBridge do
  let(:user)         { create(:user) }
  let(:device)       { create(:device, user: user) }
  let(:tool_call_id) { SecureRandom.uuid }
  let(:payload)      { { command: "terminal.execute", payload: { binary: "ls", args: ["/tmp"], cwd: "/tmp" } } }

  after { AgentToolCallRegistry.delete(tool_call_id) }

  describe "TOOL_CALL_TIMEOUT_SECONDS" do
    it "is exactly 15 seconds (TOOL-07)" do
      expect(described_class::TOOL_CALL_TIMEOUT_SECONDS).to eq(15)
    end
  end

  describe ".dispatch" do
    it "broadcasts to device_<id> with the payload merged with tool_call_id, then waits on Queue#pop" do
      expected_payload = payload.merge(tool_call_id: tool_call_id)
      expect(ActionCable.server).to receive(:broadcast).with("device_#{device.id}", expected_payload)

      # Deliver via a background thread so dispatch unblocks
      deliverer = Thread.new do
        sleep 0.05
        described_class.deliver(tool_call_id, { result: { stdout: "ok" } })
      end

      result = described_class.dispatch(device: device, payload: payload, tool_call_id: tool_call_id)
      deliverer.join

      expect(result).to eq({ result: { stdout: "ok" } })
    end

    it "returns { error: 'tool_timeout' } when no response arrives" do
      # Stub the Queue#pop returned by register to fast-timeout (avoid 15s real wait).
      fake_queue = Queue.new
      allow(AgentToolCallRegistry).to receive(:register).with(tool_call_id).and_return(fake_queue)
      allow(fake_queue).to receive(:pop).with(timeout: 15).and_return(nil)
      allow(ActionCable.server).to receive(:broadcast)

      result = described_class.dispatch(device: device, payload: payload, tool_call_id: tool_call_id)
      expect(result).to eq({ error: "tool_timeout" })
    end

    it "deletes the registry entry on return (success path)" do
      allow(ActionCable.server).to receive(:broadcast)
      deliverer = Thread.new do
        sleep 0.05
        described_class.deliver(tool_call_id, { result: { stdout: "ok" } })
      end
      described_class.dispatch(device: device, payload: payload, tool_call_id: tool_call_id)
      deliverer.join
      expect(AgentToolCallRegistry.fetch(tool_call_id)).to be_nil
    end

    it "deletes the registry entry on timeout path" do
      allow(AgentToolCallRegistry).to receive(:register).with(tool_call_id).and_call_original
      allow(ActionCable.server).to receive(:broadcast)
      allow_any_instance_of(Queue).to receive(:pop).with(timeout: 15).and_return(nil)

      described_class.dispatch(device: device, payload: payload, tool_call_id: tool_call_id)
      expect(AgentToolCallRegistry.fetch(tool_call_id)).to be_nil
    end
  end

  describe ".deliver" do
    it "pushes the result onto the registered Queue" do
      queue = AgentToolCallRegistry.register(tool_call_id)
      described_class.deliver(tool_call_id, { result: 1 })
      expect(queue.pop(timeout: 1)).to eq({ result: 1 })
    end

    it "is a silent no-op (with warn-log) when the id is not registered (D-09 late response)" do
      expect(Rails.logger).to receive(:warn).with(/\[CommandBridge\] late response for #{tool_call_id}/)
      expect { described_class.deliver(tool_call_id, { result: 1 }) }.not_to raise_error
    end
  end
end
