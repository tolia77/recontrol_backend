# frozen_string_literal: true

require "rails_helper"

RSpec.describe AssistantChannel, type: :channel do
  let(:owner)      { create(:user) }
  let(:other_user) { create(:user) }
  let(:device)     { create(:device, user: owner) }

  describe "#subscribed" do
    context "when the operator owns the target device" do
      before do
        stub_connection current_user: owner, client_type: "web", target_device: device
      end

      it "confirms the subscription and streams from the assistant_<user>_to_<device> stream" do
        subscribe
        expect(subscription).to be_confirmed
        expect(subscription).to have_stream_for("assistant_#{owner.id}_to_#{device.id}")
      end
    end

    context "when the operator does NOT own the target device" do
      before do
        stub_connection current_user: other_user, client_type: "web", target_device: device
      end

      it "rejects the subscription and does NOT stream" do
        expect(Rails.logger).to receive(:warn).with(/\[AssistantChannel\] Rejecting subscription/).at_least(:once)
        subscribe
        expect(subscription).to be_rejected
      end
    end

    context "when target_device is nil" do
      before do
        stub_connection current_user: owner, client_type: "web", target_device: nil
      end

      it "rejects the subscription" do
        allow(Rails.logger).to receive(:warn)
        subscribe
        expect(subscription).to be_rejected
      end
    end
  end

  describe "#run_prompt" do
    before do
      stub_connection current_user: owner, client_type: "web", target_device: device
      subscribe
    end

    it "transmits an accepted envelope with a SecureRandom.uuid session_token" do
      perform :run_prompt, { "prompt" => "list /tmp", "model" => "anthropic/claude-3.5-sonnet" }
      last = transmissions.last
      expect(last["type"]).to eq("accepted")
      expect(last["session_token"]).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
      expect(last["model"]).to eq("anthropic/claude-3.5-sonnet")
    end

    it "rejects an unauthorised model with type=error message=invalid_model" do
      perform :run_prompt, { "prompt" => "hi", "model" => "evil/llm" }
      last = transmissions.last
      expect(last["type"]).to eq("error")
      expect(last["message"]).to eq("invalid_model")
    end

    it "rejects an empty prompt with type=error message=empty_prompt" do
      perform :run_prompt, { "prompt" => "   ", "model" => "anthropic/claude-3.5-sonnet" }
      last = transmissions.last
      expect(last["type"]).to eq("error")
      expect(last["message"]).to eq("empty_prompt")
    end
  end

  describe "#stop_loop" do
    before do
      stub_connection current_user: owner, client_type: "web", target_device: device
      subscribe
    end

    it "is a no-op before run_prompt has been called (no @agent_runner exists yet)" do
      expect { perform :stop_loop }.not_to raise_error
    end
  end

  describe "#unsubscribed" do
    before do
      stub_connection current_user: owner, client_type: "web", target_device: device
      subscribe
    end

    it "kills the agent thread and joins for up to 1.0 seconds when @agent_thread is set" do
      fake_thread = instance_double(Thread)
      expect(fake_thread).to receive(:kill)
      expect(fake_thread).to receive(:join).with(1.0).and_return(fake_thread)
      subscription.instance_variable_set(:@agent_thread, fake_thread)

      subscription.unsubscribe_from_channel
    end

    it "logs a warn when join times out (thread did not unwind in 1s)" do
      fake_thread = instance_double(Thread)
      allow(fake_thread).to receive(:kill)
      allow(fake_thread).to receive(:join).with(1.0).and_return(nil)
      subscription.instance_variable_set(:@agent_thread, fake_thread)
      expect(Rails.logger).to receive(:warn).with(/\[AssistantChannel\] unsubscribed timeout/)

      subscription.unsubscribe_from_channel
    end

    it "is a no-op when @agent_thread is nil" do
      expect { subscription.unsubscribe_from_channel }.not_to raise_error
    end
  end
end
