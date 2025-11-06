require 'rails_helper'
require_relative '../support/auth_helpers'

RSpec.describe '/permissions_groups', type: :request do
  include AuthHelpers

  let(:password) { 'Password123' }
  let!(:user) { create(:user, password: password) }
  let!(:other_user) { create(:user, password: password) }
  let!(:admin) { create(:user, :admin, password: password) }

  describe 'GET /permissions_groups (index)' do
    before do
      create_list(:permissions_group, 3, user: user, name: 'MineGroup')
      create_list(:permissions_group, 2, user: other_user, name: 'OtherGroup')
    end

    it 'returns own groups for regular user with pagination' do
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      get permissions_groups_url, headers: headers, params: { page: 1, per_page: 2 }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['items'].length).to eq(2)
      expect(body['meta']['total']).to eq(3)
      expect(body['items'].all? { |g| g['user_id'] == user.id }).to be true
    end

    it 'returns all groups for admin' do
      signed = sign_in_user(admin)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      get permissions_groups_url, headers: headers, params: { per_page: 10 }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['meta']['total']).to eq(5)
    end

    it 'requires authentication' do
      get permissions_groups_url, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'GET /permissions_groups/:id (show)' do
    let!(:group) { create(:permissions_group, user: user, name: 'Showable') }

    it 'allows owner to view group' do
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      get permissions_group_url(group), headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['item']['id']).to eq(group.id)
    end

    it 'allows admin to view any group' do
      signed = sign_in_user(admin)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      get permissions_group_url(group), headers: headers, as: :json
      expect(response).to have_http_status(:ok)
    end

    it 'forbids non-owner non-admin' do
      signed = sign_in_user(other_user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      get permissions_group_url(group), headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'POST /permissions_groups (create)' do
    it 'creates group for current user ignoring provided user_id for regular user' do
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      post permissions_groups_url, headers: headers, params: { permissions_group: { name: 'NewPG', user_id: other_user.id, see_screen: true } }, as: :json
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['item']['user_id']).to eq(user.id)
      expect(body['item']['see_screen']).to eq(true)
    end

    it 'allows admin to create group with specified user_id' do
      signed = sign_in_user(admin)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      post permissions_groups_url, headers: headers, params: { permissions_group: { name: 'AdminPG', user_id: other_user.id, access_terminal: true } }, as: :json
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['item']['user_id']).to eq(other_user.id)
      expect(body['item']['access_terminal']).to eq(true)
    end

    it 'requires authentication' do
      post permissions_groups_url, params: { permissions_group: { name: 'NoAuth' } }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'PATCH /permissions_groups/:id (update)' do
    let!(:group) { create(:permissions_group, user: user, name: 'Updatable', see_screen: false) }

    it 'updates own group' do
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      patch permissions_group_url(group), headers: headers, params: { permissions_group: { see_screen: true, name: 'Updated' } }, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['item']['see_screen']).to eq(true)
      expect(body['item']['name']).to eq('Updated')
    end

    it 'forbids other user non-admin from updating' do
      signed = sign_in_user(other_user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      patch permissions_group_url(group), headers: headers, params: { permissions_group: { see_screen: true } }, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it 'allows admin to update any group' do
      signed = sign_in_user(admin)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      patch permissions_group_url(group), headers: headers, params: { permissions_group: { access_mouse: true } }, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['item']['access_mouse']).to eq(true)
    end
  end

  describe 'DELETE /permissions_groups/:id (destroy)' do
    let!(:group) { create(:permissions_group, user: user) }

    it 'destroys own group' do
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      expect { delete permissions_group_url(group), headers: headers, as: :json }.to change(PermissionsGroup, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it 'forbids other user non-admin from destroying' do
      group2 = create(:permissions_group, user: other_user)
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      expect { delete permissions_group_url(group2), headers: headers, as: :json }.not_to change(PermissionsGroup, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it 'allows admin to destroy any group' do
      group3 = create(:permissions_group, user: other_user)
      signed = sign_in_user(admin)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      expect { delete permissions_group_url(group3), headers: headers, as: :json }.to change(PermissionsGroup, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end
  end
end

