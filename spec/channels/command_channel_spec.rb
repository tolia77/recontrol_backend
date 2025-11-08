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
  end
end
