# Ensure support helpers are loaded when running this spec directly
require_relative "../support/auth_helpers"

require 'rails_helper'

RSpec.describe "/devices", type: :request do
  include AuthHelpers

  let(:password) { "Password123" }
  let!(:user) { create(:user, password: password) }
  let!(:other_user) { create(:user, password: password) }
  let!(:admin) { create(:user, :admin, password: password) }

  describe "GET /devices (index)" do
    before do
      create_list(:device, 3, user: user, name: "UserDevice", status: "active", last_active_at: 2.hours.ago)
      create_list(:device, 2, user: user, name: "OldDevice", status: "inactive", last_active_at: 3.days.ago)
      create_list(:device, 4, user: other_user, name: "OtherDevice", status: "active", last_active_at: 30.minutes.ago)
    end

    it "forbids regular user (admin only)" do
      signed = sign_in_user(user, client_type: "web")
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      get "/devices", headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "returns all filtered devices for admin with user_id and last_active range + sorting" do
      signed = sign_in_user(admin, client_type: "web")
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      from = 1.hour.ago.iso8601
      to   = Time.current.iso8601
      get devices_url, headers: headers, params: {
        user_id: other_user.id,
        status: "active",
        last_active_from: from,
        last_active_to: to,
        sort_by: "last_active_at",
        sort_dir: "asc"
      }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["devices"].all? { |d| d["user_id"] == other_user.id }).to be true
      times = body["devices"].map { |d| Time.parse(d["last_active_at"]) }
      expect(times).to eq(times.sort) # asc order
    end

    it "falls back to created_at sorting when invalid sort_by provided" do
      signed = sign_in_user(admin, client_type: "web")
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      get devices_url, headers: headers, params: { sort_by: "___bad___", sort_dir: "asc", per_page: 5 }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      created = body["devices"].map { |d| Time.parse(d["created_at"]) }
      expect(created).to eq(created.sort) # asc fallback
    end

    it "returns unauthorized for unauthenticated requests" do
      get devices_url, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /devices/me" do
    before do
      create_list(:device, 2, user: user, name: "Mine", status: "active", last_active_at: 10.minutes.ago)
      shared_device = create(:device, user: other_user, name: "SharedX", status: "active", last_active_at: 5.minutes.ago)
      create(:device_share, device: shared_device, user: user) # shared to current user
    end

    it "filters by owner=me" do
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      get devices_me_url, headers: headers, params: { owner: "me" }
      body = JSON.parse(response.body)
      expect(body["devices"].length).to eq(2)
      expect(body["devices"].all? { |d| d["user_id"] == user.id }).to be true
    end

    it "filters by owner=shared" do
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      get devices_me_url, headers: headers, params: { owner: "shared" }
      body = JSON.parse(response.body)
      expect(body["devices"].length).to eq(1)
      expect(body["devices"].all? { |d| d["user_id"] == other_user.id }).to be true
    end

    it "returns both when owner omitted and supports name + last_active range + sorting" do
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])
      from = 15.minutes.ago.iso8601
      to   = Time.current.iso8601
      get devices_me_url, headers: headers, params: {
        name: "x", # matches SharedX
        last_active_from: from,
        last_active_to: to,
        sort_by: "name",
        sort_dir: "asc"
      }
      body = JSON.parse(response.body)
      names = body["devices"].map { |d| d["name"] }
      expect(names).to eq(names.sort) # asc by name
      expect(names).to include("SharedX")
    end

    it "requires authentication" do
      get devices_me_url, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /devices/:id (show)" do
    let!(:device) { create(:device, user: user, name: "Visible") }
    let!(:other_device) { create(:device, user: other_user) }

    it "allows owner to view device" do
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      get device_url(device), headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["id"]).to eq(device.id)
    end

    it "allows admin to view any device" do
      signed = sign_in_user(admin)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      get device_url(other_device), headers: headers, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["id"]).to eq(other_device.id)
    end

    it "returns forbidden for non-owner non-admin" do
      signed = sign_in_user(other_user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      get device_url(device), headers: headers, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "returns not_found for missing device" do
      signed = sign_in_user(admin)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      get device_url(id: 0), headers: headers, as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /devices (create)" do
    it "allows signed-in user to create device for themselves" do
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      expect {
        post devices_url, headers: headers, params: { device: { name: "New Device", status: "active" } }, as: :json
      }.to change(Device, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      p body
      expect(body["user"]["id"]).to eq(user.id)
      expect(body["name"]).to eq("New Device")
    end

    it "allows admin to create device for another user using user_id" do
      signed = sign_in_user(admin)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      expect {
        post devices_url, headers: headers, params: { device: { name: "Admin Created", user_id: other_user.id } }, as: :json
      }.to change(Device, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["user"]["id"]).to eq(other_user.id)
    end

    it "returns 422 for invalid params" do
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      post devices_url, headers: headers, params: { device: { name: "" } }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body).to have_key("name")
    end

    it "requires authentication" do
      post devices_url, params: { device: { name: "NoAuth" } }, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "PATCH /devices/:id (update)" do
    let!(:device) { create(:device, user: user, name: "Updatable", status: "active") }

    it "allows owner to update device" do
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      patch device_url(device), headers: headers, params: { device: { name: "Updated", status: "inactive" } }, as: :json
      expect(response).to have_http_status(:ok)
      device.reload
      expect(device.name).to eq("Updated")
      expect(device.status).to eq("inactive")
    end

    it "allows admin to update any device" do
      signed = sign_in_user(admin)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      patch device_url(device), headers: headers, params: { device: { name: "AdminUpdated" } }, as: :json
      expect(response).to have_http_status(:ok)
      device.reload
      expect(device.name).to eq("AdminUpdated")
    end

    it "forbids non-owner non-admin from updating" do
      signed = sign_in_user(other_user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      patch device_url(device), headers: headers, params: { device: { name: "X" } }, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "returns 422 for invalid update params" do
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      patch device_url(device), headers: headers, params: { device: { name: "" } }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body).to have_key("name")
    end
  end

  describe "DELETE /devices/:id (destroy)" do
    let!(:device) { create(:device, user: user) }

    it "allows owner to delete device" do
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      expect {
        delete device_url(device), headers: headers, as: :json
      }.to change(Device, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it "allows admin to delete any device" do
      device2 = create(:device, user: other_user)
      signed = sign_in_user(admin)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      expect {
        delete device_url(device2), headers: headers, as: :json
      }.to change(Device, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it "forbids non-owner non-admin from deleting" do
      device3 = create(:device, user: other_user)
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      expect {
        delete device_url(device3), headers: headers, as: :json
      }.to_not change(Device, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it "requires authentication" do
      delete device_url(device), as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
