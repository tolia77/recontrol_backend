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
      # Plan 5: run_prompt now spawns an AgentRunner thread. Mock the runner
      # construction so the channel spec does not depend on OpenRouter credentials.
      @fake_runner = instance_double(AgentRunner, run: nil, request_stop: nil)
      allow(AgentRunner).to receive(:new).and_return(@fake_runner)
    end

    it "transmits an accepted envelope with a SecureRandom.uuid session_token" do
      perform :run_prompt, { "prompt" => "list /tmp", "model" => "anthropic/claude-sonnet-4.6" }
      accepted = transmissions.find { |t| t["type"] == "accepted" }
      expect(accepted).not_to be_nil
      expect(accepted["session_token"]).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
      expect(accepted["model"]).to eq("anthropic/claude-sonnet-4.6")
      subscription.instance_variable_get(:@agent_thread)&.join(1.0)
    end

    it "rejects an unauthorised model with type=error message=invalid_model" do
      perform :run_prompt, { "prompt" => "hi", "model" => "evil/llm" }
      last = transmissions.last
      expect(last["type"]).to eq("error")
      expect(last["message"]).to eq("invalid_model")
    end

    it "rejects an empty prompt with type=error message=empty_prompt" do
      perform :run_prompt, { "prompt" => "   ", "model" => "anthropic/claude-sonnet-4.6" }
      last = transmissions.last
      expect(last["type"]).to eq("error")
      expect(last["message"]).to eq("empty_prompt")
    end
  end

  describe "#run_prompt -- runner spawn (Plan 5 wiring)" do
    before do
      stub_connection current_user: owner, client_type: "web", target_device: device
      subscribe
    end

    it "constructs AgentRunner with the validated model and minted session_token, spawns a Thread" do
      fake_runner = instance_double(AgentRunner, run: nil)

      expect(AgentRunner).to receive(:new).with(
        hash_including(
          user: owner,
          device: device,
          prompt: "list /tmp",
          model: "anthropic/claude-sonnet-4.6",
          session_token: match(/\A[0-9a-f-]{36}\z/)
        )
      ).and_return(fake_runner)

      perform :run_prompt, { "prompt" => "list /tmp", "model" => "anthropic/claude-sonnet-4.6" }

      thread = subscription.instance_variable_get(:@agent_thread)
      expect(thread).to be_a(Thread)
      thread.join(1.0)
    end

    it "honors a UUID-shaped session_token supplied by the frontend" do
      fake_runner = instance_double(AgentRunner, run: nil)
      supplied = "d15505a6-82d3-4baa-9a4d-c03c631aa43b"

      expect(AgentRunner).to receive(:new).with(
        hash_including(session_token: supplied)
      ).and_return(fake_runner)

      transmitted = []
      allow(subscription).to receive(:transmit) { |payload| transmitted << payload }

      perform :run_prompt, {
        "prompt" => "list /tmp",
        "model" => "anthropic/claude-sonnet-4.6",
        "session_token" => supplied
      }
      subscription.instance_variable_get(:@agent_thread)&.join(1.0)

      accepted = transmitted.find { |p| p[:type] == "accepted" }
      expect(accepted[:session_token]).to eq(supplied)
    end

    it "ignores a malformed session_token and mints a fresh UUID" do
      fake_runner = instance_double(AgentRunner, run: nil)
      allow(AgentRunner).to receive(:new).and_return(fake_runner)

      transmitted = []
      allow(subscription).to receive(:transmit) { |payload| transmitted << payload }

      perform :run_prompt, {
        "prompt" => "x",
        "model" => "anthropic/claude-sonnet-4.6",
        "session_token" => "not-a-uuid"
      }
      subscription.instance_variable_get(:@agent_thread)&.join(1.0)

      accepted = transmitted.find { |p| p[:type] == "accepted" }
      expect(accepted[:session_token]).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
      expect(accepted[:session_token]).not_to eq("not-a-uuid")
    end

    it "transmits accepted BEFORE spawning the thread (so the frontend has the session_token)" do
      fake_runner = instance_double(AgentRunner)
      allow(fake_runner).to receive(:run)
      allow(AgentRunner).to receive(:new).and_return(fake_runner)

      order = []
      allow(subscription).to receive(:transmit) { |payload| order << [:transmit, payload[:type]] }
      original_thread_new = Thread.method(:new)
      allow(Thread).to receive(:new) do |*args, &block|
        order << [:thread_new]
        original_thread_new.call(*args, &block)
      end

      perform :run_prompt, { "prompt" => "x", "model" => "anthropic/claude-sonnet-4.6" }
      subscription.instance_variable_get(:@agent_thread)&.join(1.0)

      # First event is the accepted transmit; the thread spawn happens after.
      expect(order.first).to eq([:transmit, "accepted"])
      expect(order.find { |e| e == [:thread_new] }).not_to be_nil
      expect(order.index([:transmit, "accepted"])).to be < order.index([:thread_new])
    end
  end

  describe "#stop_loop -- runner wired" do
    before do
      stub_connection current_user: owner, client_type: "web", target_device: device
      subscribe
    end

    it "calls request_stop on the runner instance" do
      fake_runner = instance_double(AgentRunner, run: nil)
      allow(AgentRunner).to receive(:new).and_return(fake_runner)
      expect(fake_runner).to receive(:request_stop)

      perform :run_prompt, { "prompt" => "x", "model" => "anthropic/claude-sonnet-4.6" }
      perform :stop_loop
      subscription.instance_variable_get(:@agent_thread)&.join(1.0)
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

  describe "#confirm_tool_call (Phase 19 / SAFETY-07)" do
    let(:owner)  { create(:user) }
    let(:device) { create(:device, user: owner) }

    before do
      stub_connection current_user: owner, client_type: "web", target_device: device
      subscribe
    end

    it "delivers operator allow decision to ConfirmationRegistry" do
      cid = SecureRandom.uuid
      queue = ConfirmationRegistry.register(cid)
      perform :confirm_tool_call, "confirmation_id" => cid, "decision" => "allow"
      expect(queue.pop(true)).to eq({ decision: "allow" })
      ConfirmationRegistry.delete(cid)
    end

    it "delivers operator deny decision to ConfirmationRegistry" do
      cid = SecureRandom.uuid
      queue = ConfirmationRegistry.register(cid)
      perform :confirm_tool_call, "confirmation_id" => cid, "decision" => "deny"
      expect(queue.pop(true)).to eq({ decision: "deny" })
      ConfirmationRegistry.delete(cid)
    end

    it "rejects unknown decision values without calling deliver" do
      cid = SecureRandom.uuid
      expect(ConfirmationRegistry).not_to receive(:deliver)
      expect(Rails.logger).to receive(:warn).with(/invalid decision=bogus/)
      perform :confirm_tool_call, "confirmation_id" => cid, "decision" => "bogus"
    end

    it "is a silent no-op for missing/expired confirmation_id" do
      expect { perform :confirm_tool_call, "confirmation_id" => "missing", "decision" => "allow" }
        .not_to raise_error
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

  describe "#unsubscribed AiSession finalize-on-tab-close (Phase 19 / D-11)" do
    let(:owner)  { create(:user) }
    let(:device) { create(:device, user: owner) }

    before do
      stub_connection current_user: owner, client_type: "web", target_device: device
      subscribe
    end

    it "does NOT contain the Phase 19 TODO comment" do
      expect(File.read(Rails.root.join("app/channels/assistant_channel.rb")))
        .not_to include("TODO Phase 19")
    end

    it "finalizes AiSession with stop_reason='tab_closed' when ended_at is NULL on tab close" do
      ai_session = AiSession.create!(
        user: owner,
        device: device,
        started_at: Time.current,
        model: "anthropic/claude-sonnet-4.6"
      )
      runner = double("AgentRunner", ai_session: ai_session, request_stop: nil)
      subscription.instance_variable_set(:@agent_runner, runner)
      subscription.instance_variable_set(:@agent_thread, Thread.new { sleep })

      unsubscribe

      ai_session.reload
      expect(ai_session.ended_at).to be_present
      expect(ai_session.stop_reason).to eq("tab_closed")
    end

    it "is a no-op when @agent_runner.ai_session is nil" do
      runner = double("AgentRunner", ai_session: nil, request_stop: nil)
      subscription.instance_variable_set(:@agent_runner, runner)
      subscription.instance_variable_set(:@agent_thread, nil)
      expect { unsubscribe }.not_to raise_error
    end

    it "does NOT re-finalize an already-closed AiSession" do
      ai_session = AiSession.create!(
        user: owner,
        device: device,
        started_at: 1.minute.ago,
        ended_at: 30.seconds.ago,
        stop_reason: "completed",
        turn_count: 2,
        input_tokens: 100,
        output_tokens: 50,
        model: "anthropic/claude-sonnet-4.6"
      )
      runner = double("AgentRunner", ai_session: ai_session, request_stop: nil)
      subscription.instance_variable_set(:@agent_runner, runner)
      subscription.instance_variable_set(:@agent_thread, nil)

      unsubscribe

      ai_session.reload
      expect(ai_session.stop_reason).to eq("completed")
    end
  end
end
