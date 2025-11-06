require 'rails_helper'
require_relative '../support/auth_helpers'

RSpec.describe '/device_shares', type: :request do
  include AuthHelpers

  let(:password) { 'Password123' }
  let!(:owner) { create(:user, password: password) }
  let!(:recipient) { create(:user, password: password) }
  let!(:admin) { create(:user, :admin, password: password) }
  let!(:device) { create(:device, user: owner, name: 'Owner PC') }
  let!(:group) { create(:permissions_group, user: owner, name: 'Base PG', see_screen: true) }

  describe 'GET /device_shares (index)' do
    before do
      create(:device_share, device: device, user: recipient, permissions_group: group)
    end

    it 'lists shares for device owner (owning or receiving)' do
      signed = sign_in_user(owner)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      get device_shares_url, headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['items'].length).to be >= 1
      expect(body['items'].first['device']['id']).to eq(device.id)
    end

    it 'filters by user_id for admin' do
      signed = sign_in_user(admin)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      get device_shares_url, headers: headers, params: { user_id: recipient.id }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['items'].all? { |s| s['user']['id'] == recipient.id }).to be true
    end

    it 'requires authentication' do
      get device_shares_url, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET /device_shares/:id (show)' do
    let!(:share) { create(:device_share, device: device, user: recipient, permissions_group: group) }

    it 'allows device owner to view' do
      signed = sign_in_user(owner)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      get device_share_url(share), headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['item']['device']['id']).to eq(device.id)
    end

    it 'allows recipient to view' do
      signed = sign_in_user(recipient)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      get device_share_url(share), headers: headers, as: :json
      expect(response).to have_http_status(:ok)
    end

    it 'forbids unrelated user' do
      other = create(:user, password: password)
      signed = sign_in_user(other)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      get device_share_url(share), headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'POST /device_shares (create)' do
    it 'allows device owner to create with permissions_group_id' do
      signed = sign_in_user(owner)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      params = { device_share: { device_id: device.id, user_id: recipient.id, permissions_group_id: group.id } }
      post device_shares_url, headers: headers, params: params, as: :json
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['item']['device']['id']).to eq(device.id)
      expect(body['item']['user']['id']).to eq(recipient.id)
    end

    it 'allows device owner to create with nested permissions_group_attributes' do
      signed = sign_in_user(owner)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      params = { device_share: { device_id: device.id, user_email: recipient.email, permissions_group_attributes: { name: 'Nested PG', see_screen: true } } }
      post device_shares_url, headers: headers, params: params, as: :json
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['item']['permissions_group']['name']).to eq('Nested PG')
      expect(body['item']['user']['email']).to eq(recipient.email)
    end

    it 'forbids non-owner from creating' do
      other = create(:user, password: password)
      signed = sign_in_user(other)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      params = { device_share: { device_id: device.id, user_id: recipient.id, permissions_group_id: group.id } }
      post device_shares_url, headers: headers, params: params, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it 'returns not_found when device missing' do
      signed = sign_in_user(owner)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      params = { device_share: { device_id: SecureRandom.uuid, user_id: recipient.id, permissions_group_id: group.id } }
      post device_shares_url, headers: headers, params: params, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'PATCH /device_shares/:id (update)' do
    let!(:share) { create(:device_share, device: device, user: recipient, permissions_group: group) }

    it 'allows device owner to update recipient via email and nested group' do
      new_recipient = create(:user, password: password)
      signed = sign_in_user(owner)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      params = { device_share: { user_email: new_recipient.email, permissions_group_attributes: { name: 'Updated PG', access_terminal: true } } }
      patch device_share_url(share), headers: headers, params: params, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['item']['user']['id']).to eq(new_recipient.id)
      expect(body['item']['permissions_group']['access_terminal']).to eq(true)
    end

    it 'forbids non-owner from updating' do
      signed = sign_in_user(recipient)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      patch device_share_url(share), headers: headers, params: { device_share: { status: 'revoked' } }, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'DELETE /device_shares/:id (destroy)' do
    it 'allows device owner to destroy share' do
      share = create(:device_share, device: device, user: recipient, permissions_group: group)
      signed = sign_in_user(owner)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      expect { delete device_share_url(share), headers: headers, as: :json }.to change(DeviceShare, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it 'forbids non-owner from destroying' do
      share = create(:device_share, device: device, user: recipient, permissions_group: group)
      signed = sign_in_user(recipient)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      expect { delete device_share_url(share), headers: headers, as: :json }.not_to change(DeviceShare, :count)
      expect(response).to have_http_status(:forbidden)
    end
  end
end

