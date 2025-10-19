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
      create_list(:device, 3, user: user, name: "UserDevice", status: "active")
      create_list(:device, 2, user: user, name: "OldDevice", status: "inactive")
      create_list(:device, 4, user: other_user, name: "OtherDevice", status: "active")
    end

    it "returns own devices for regular user and supports status and name filters and pagination" do
      signed = sign_in_user(user, client_type: "web")
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      get devices_url, headers: headers, params: { status: "active", name: "user", page: 1, per_page: 2 }, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["devices"].length).to eq(2)
      expect(body["meta"]["total"]).to eq(3)
      expect(body["devices"].all? { |d| d["user_id"] == user.id }).to be true
    end

    it "returns all devices for admin and supports user_id filter" do
      signed = sign_in_user(admin, client_type: "web")
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      get devices_url, headers: headers, params: { user_id: other_user.id, per_page: 10 }, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["devices"].all? { |d| d["user_id"] == other_user.id }).to be true
      expect(body["meta"]["total"]).to eq(4)
    end

    it "returns unauthorized for unauthenticated requests" do
      get devices_url, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /devices/me" do
    before do
      create_list(:device, 2, user: user, name: "Mine", status: "active")
      create(:device, user: other_user, name: "Other", status: "active")
    end

    it "returns current user's devices with pagination and filters" do
      signed = sign_in_user(user)
      headers = auth_headers(signed[:access_token], signed[:refresh_token])

      get me_devices_url, headers: headers, params: { name: "mine", page: 1, per_page: 5 }, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["devices"].length).to eq(2)
      expect(body["devices"].all? { |d| d["user_id"] == user.id }).to be true
    end

    it "requires authentication" do
      get me_devices_url, as: :json
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
      expect(body["user_id"]).to eq(user.id)
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
      expect(body["user_id"]).to eq(other_user.id)
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
