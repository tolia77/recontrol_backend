require 'rails_helper'
require_relative '../support/auth_helpers'

RSpec.describe '/device_shares/me', type: :request do
  include AuthHelpers

  let(:password) { 'Password123' }
  let!(:owner) { create(:user, password: password) }
  let!(:recipient) { create(:user, password: password) }
  let!(:other) { create(:user, password: password) }
  let!(:device_owned_1) { create(:device, user: owner, name: 'Owner Box 1', status: 'active') }
  let!(:device_owned_2) { create(:device, user: owner, name: 'Owner Box 2', status: 'inactive') }
  let!(:device_other) { create(:device, user: other, name: 'Other Box', status: 'active') }
  let!(:pg_owner) { create(:permissions_group, user: owner, name: 'Owner PG', see_screen: true, access_terminal: true) }
  let!(:pg_other) { create(:permissions_group, user: other, name: 'Other PG', see_screen: true) }

  # Shares outgoing (owner shares devices) + incoming (owner receives from other)
  let!(:outgoing_share_1) { create(:device_share, device: device_owned_1, user: recipient, permissions_group: pg_owner, status: 'active', expires_at: 5.days.from_now) }
  let!(:outgoing_share_2) { create(:device_share, device: device_owned_2, user: recipient, permissions_group: pg_owner, status: 'revoked', expires_at: 3.days.from_now) }
  let!(:incoming_share) { create(:device_share, device: device_other, user: owner, permissions_group: pg_other, status: 'active', expires_at: 7.days.from_now) }
  let!(:past_share) do
    create(:device_share, device: device_owned_1, user: recipient, permissions_group: pg_owner, status: 'active', created_at: 2.days.ago, updated_at: 2.days.ago)
  end

  def me_headers(user)
    signed = sign_in_user(user)
    auth_headers(signed[:access_token], signed[:refresh_token])
  end

  it 'requires authentication' do
    get device_shares_me_url, as: :json
    expect(response).to have_http_status(:unauthorized)
  end

  it 'returns both incoming and outgoing shares by default with permissions included' do
    get device_shares_me_url, headers: me_headers(owner), as: :json
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expected_ids = [outgoing_share_1.id, outgoing_share_2.id, incoming_share.id, past_share.id]
    expect(body['items'].map { |i| i['id'] }).to match_array(expected_ids)
    pg = body['items'].first['permissions_group']
    expect(pg.keys).to include('see_screen', 'access_terminal')
  end

  it 'filters outgoing shares via direction=outgoing (includes past share)' do
    get device_shares_me_url, headers: me_headers(owner), params: { direction: 'outgoing' }
    body = JSON.parse(response.body)
    expected_ids = [outgoing_share_1.id, outgoing_share_2.id, past_share.id]
    expect(body['items'].map { |i| i['id'] }).to match_array(expected_ids)
    expect(body['items'].none? { |i| i['id'] == incoming_share.id }).to be true
  end

  it 'filters incoming shares via direction=incoming' do
    get device_shares_me_url, headers: me_headers(owner), params: { direction: 'incoming' }
    body = JSON.parse(response.body)
    expect(body['items'].map { |i| i['id'] }).to eq([incoming_share.id])
  end

  it 'filters by device_id for a device with single share' do
    # Use device_owned_2 which only has outgoing_share_2
    get device_shares_me_url, headers: me_headers(owner), params: { device_id: device_owned_2.id }
    body = JSON.parse(response.body)
    expect(body['items'].length).to eq(1)
    expect(body['items'].first['id']).to eq(outgoing_share_2.id)
  end

  it 'filters by status' do
    get device_shares_me_url, headers: me_headers(owner), params: { status: 'revoked' }
    body = JSON.parse(response.body)
    expect(body['items'].map { |i| i['id'] }).to eq([outgoing_share_2.id])
  end

  it 'filters by permissions_group_id' do
    get device_shares_me_url, headers: me_headers(owner), params: { permissions_group_id: pg_owner.id }
    body = JSON.parse(response.body)
    expect(body['items'].map { |i| i['permissions_group']['id'] }).to all(eq(pg_owner.id))
  end

  it 'filters by user_email (recipient)' do
    get device_shares_me_url, headers: me_headers(owner), params: { user_email: recipient.email }
    body = JSON.parse(response.body)
    expect(body['items'].all? { |i| i['user']['email'] == recipient.email }).to be true
  end

  it 'filters by created_from and created_to range' do
    from = 3.days.ago.iso8601
    to = 1.day.ago.iso8601
    get device_shares_me_url, headers: me_headers(owner), params: { created_from: from, created_to: to }
    body = JSON.parse(response.body)
    ids = body['items'].map { |i| i['id'] }
    expect(ids).to eq([past_share.id])
  end

  it 'applies sorting by status asc' do
    get device_shares_me_url, headers: me_headers(owner), params: { sort_by: 'status', sort_dir: 'asc' }
    body = JSON.parse(response.body)
    statuses = body['items'].map { |i| i['status'] }
    expect(statuses).to eq(statuses.sort)
  end

  it 'falls back to created_at desc when invalid sort_by' do
    get device_shares_me_url, headers: me_headers(owner), params: { sort_by: '__bad__' }
    body = JSON.parse(response.body)
    created = body['items'].map { |i| Time.parse(i['created_at']) }
    expect(created).to eq(created.sort.reverse) # default desc
  end

  it 'paginates results' do
    # create more shares to test pagination
    extra_pg = create(:permissions_group, user: owner)
    6.times do
      create(:device_share, device: device_owned_1, user: recipient, permissions_group: extra_pg)
    end
    get device_shares_me_url, headers: me_headers(owner), params: { per_page: 5, page: 1 }
    body = JSON.parse(response.body)
    expect(body['items'].length).to eq(5)
    expect(body['meta']['total']).to be > 5
  end
end
