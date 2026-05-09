require 'rails_helper'

RSpec.describe CommandChannel, type: :channel do
  let(:owner) { create(:user) }
  let(:shared_user) { create(:user) }
  let(:device) { create(:device, user: owner) }

  context 'web client' do
    before do
      stub_connection current_user: current_user, client_type: 'web', target_device: device
    end

    context 'as owner' do
      let(:current_user) { owner }

      it 'forwards any command to device stream' do
        subscribe
        expect(ActionCable.server).to receive(:broadcast).with(
          "device_#{device.id}", hash_including(command: 'terminal.execute')
        )
        perform :receive, { 'command' => 'terminal.execute', 'payload' => { 'cmd' => 'dir' }, 'id' => '1' }
      end

      it 'forwards webrtc.offer to device stream' do
        subscribe
        expect(ActionCable.server).to receive(:broadcast).with(
          "device_#{device.id}", hash_including(command: 'webrtc.offer')
        )
        perform :receive, { 'command' => 'webrtc.offer', 'payload' => { 'sdp' => 'v=0...' }, 'id' => '1' }
      end

      it 'subscribes to owner stream to receive screen data' do
        subscribe
        expect(subscription).to be_confirmed
        expect(subscription).to have_stream_for("user_#{owner.id}_to_#{device.id}")
      end
    end

    context 'as shared user without permissions' do
      let(:current_user) { shared_user }

      it 'blocks disallowed command' do
        pg = create(:permissions_group, user: owner)
        create(:device_share, user: shared_user, device: device, permissions_group: pg)
        subscribe
        expect(ActionCable.server).not_to receive(:broadcast)
        perform :receive, { 'command' => 'terminal.execute', 'payload' => { 'cmd' => 'ls' }, 'id' => '1' }
      end

      it 'allows allowed command based on permissions' do
        pg = create(:permissions_group, user: owner, access_keyboard: true)
        create(:device_share, user: shared_user, device: device, permissions_group: pg)
        subscribe
        expect(ActionCable.server).to receive(:broadcast).with(
          "device_#{device.id}", hash_including(command: 'keyboard.press')
        )
        perform :receive, { 'command' => 'keyboard.press', 'payload' => { 'key' => 'A' }, 'id' => '2' }
      end

      it 'subscribes to owner stream to receive screen data' do
        pg = create(:permissions_group, user: owner, see_screen: true)
        create(:device_share, user: shared_user, device: device, permissions_group: pg)
        subscribe
        expect(subscription).to be_confirmed
        expect(subscription).to have_stream_for("user_#{owner.id}_to_#{device.id}")
      end
    end
  end

  context 'desktop client' do
    before do
      stub_connection current_user: owner, client_type: 'desktop', current_device: device
    end

    it 'forwards screen.frame as-is to user stream' do
      subscribe
      data = {
        'command' => 'screen.frame',
        'payload' => { 'image' => '...binary...', 'isFull' => true }
      }
      expect(ActionCable.server).to receive(:broadcast).with(
        "user_#{owner.id}_to_#{device.id}", data
      )
      perform :receive, data
    end

    it 'forwards screen.frame_batch as-is to user stream' do
      subscribe
      data = {
        'command' => 'screen.frame_batch',
        'payload' => {
          'regions' => [
            { 'image' => '...bin1...', 'isFull' => false, 'x' => 10, 'y' => 20, 'width' => 100, 'height' => 50 },
            { 'image' => '...bin2...', 'isFull' => false, 'x' => 120, 'y' => 70, 'width' => 80, 'height' => 40 }
          ]
        }
      }
      expect(ActionCable.server).to receive(:broadcast).with(
        "user_#{owner.id}_to_#{device.id}", data
      )
      perform :receive, data
    end

    it 'forwards webrtc.answer to user stream' do
      subscribe
      data = {
        'command' => 'webrtc.answer',
        'payload' => { 'sdp' => 'v=0...' }
      }
      expect(ActionCable.server).to receive(:broadcast).with(
        "user_#{owner.id}_to_#{device.id}", data
      )
      perform :receive, data
    end

    it 'forwards webrtc.ice_candidate to user stream' do
      subscribe
      data = {
        'command' => 'webrtc.ice_candidate',
        'payload' => { 'candidate' => 'candidate:...' }
      }
      expect(ActionCable.server).to receive(:broadcast).with(
        "user_#{owner.id}_to_#{device.id}", data
      )
      perform :receive, data
    end

    describe '#handle_desktop_message tool_call_id routing' do
      let(:tool_call_id) { SecureRandom.uuid }

      it 'routes responses bearing tool_call_id through CommandBridge.deliver and skips the user broadcast' do
        subscribe
        expect(CommandBridge).to receive(:deliver).with(
          tool_call_id,
          hash_including(id: 'web-msg-1', status: 'ok', result: { 'stdout' => 'hi' })
        )
        expect(ActionCable.server).not_to receive(:broadcast)

        perform :receive, {
          'tool_call_id' => tool_call_id,
          'command'      => 'terminal.execute',
          'id'           => 'web-msg-1',
          'status'       => 'ok',
          'result'       => { 'stdout' => 'hi' }
        }
      end

      it 'forwards plain (non-tool) command responses to broadcast_to_user as before (regression guard)' do
        subscribe
        expect(CommandBridge).not_to receive(:deliver)
        expect(ActionCable.server).to receive(:broadcast).with(
          "user_#{owner.id}_to_#{device.id}",
          hash_including(id: 'web-msg-2', status: 'ok')
        )

        perform :receive, {
          'command' => 'terminal.execute',
          'id'      => 'web-msg-2',
          'status'  => 'ok'
        }
      end

      it 'does not route heartbeats through CommandBridge even if a tool_call_id field is somehow present' do
        subscribe
        expect(CommandBridge).not_to receive(:deliver)
        perform :receive, { 'command' => 'heartbeat', 'tool_call_id' => 'should-not-route' }
      end
    end
  end
end
