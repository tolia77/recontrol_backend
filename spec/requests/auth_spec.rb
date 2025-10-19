require 'rails_helper'

RSpec.describe "Auth", type: :request do
  let(:password) { "Password123" }
  let(:user) { User.create!(username: "tester", email: "tester@example.com", password: password) }

  describe "POST /auth/login" do
    it "logs in web client successfully without device_id in JWT" do
      user
      post "/auth/login", params: { email: user.email, password: password, client_type: "web" }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["user_id"]).to eq(user.id)
      expect(body["access_token"]).to be_present
      expect(body["refresh_token"]).to be_present
      expect(body["device_id"]).to be_nil

      access_payload = JWTUtils.decode_access(body["access_token"])[0]
      refresh_payload = JWTUtils.decode_refresh(body["refresh_token"])[0]
      expect(access_payload["sub"]).to eq(user.id)
      expect(access_payload["device_id"]).to be_nil
      expect(refresh_payload["device_id"]).to be_nil
    end

    it "logs in desktop client with existing device_id and returns device_id in session and JWT" do
      device = Device.create!(user: user, name: "My PC")
      post "/auth/login", params: { email: user.email, password: password, client_type: "desktop", device_id: device.id }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["device_id"]).to eq(device.id)

      access_payload = JWTUtils.decode_access(body["access_token"])[0]
      refresh_payload = JWTUtils.decode_refresh(body["refresh_token"])[0]
      expect(access_payload["device_id"]).to eq(device.id)
      expect(refresh_payload["device_id"]).to eq(device.id)

      session = Session.find_by(jti: access_payload["jti"])
      expect(session).to be_present
      expect(session.device_id).to eq(device.id)
      expect(session.client_type).to eq("desktop")
    end

    it "logs in desktop client creating a new device when device_id missing, using device_name" do
      post "/auth/login", params: { email: user.email, password: password, client_type: "desktop", device_name: "Work PC" }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["device_id"]).to be_present
      device = Device.find(body["device_id"])
      expect(device.user_id).to eq(user.id)
      expect(device.name).to eq("Work PC")

      access_payload = JWTUtils.decode_access(body["access_token"])[0]
      expect(access_payload["device_id"]).to eq(device.id)
    end

    it "fails with 401 for invalid credentials" do
      post "/auth/login", params: { email: user.email, password: "wrong" }
      expect(response).to have_http_status(:unauthorized)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Invalid email or password")
    end

    it "fails when device_id does not belong to the user on desktop login" do
      other_user = User.create!(username: "other", email: "other@example.com", password: "Password123")
      foreign_device = Device.create!(user: other_user, name: "Not Yours")
      post "/auth/login", params: { email: user.email, password: password, client_type: "desktop", device_id: foreign_device.id }
      expect(response).to have_http_status(:unauthorized)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Device does not belong to user")
    end

    it "fails with 422 when desktop login has no device_id and invalid device_name" do
      post "/auth/login", params: { email: user.email, password: password, client_type: "desktop" } # no device_name
      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body).to have_key("name") # validation error on device name
    end
  end

  describe "POST /auth/register" do
    it "registers successfully and returns tokens" do
      params = { user: { username: "newbie", email: "newbie@example.com", password: "Password123" } }
      post "/auth/register", params: params
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["user_id"]).to be_present
      expect(body["access_token"]).to be_present
      expect(body["refresh_token"]).to be_present

      access_payload = JWTUtils.decode_access(body["access_token"])[0]
      expect(access_payload["sub"]).to eq(body["user_id"])
    end

    it "fails with validation errors when email missing" do
      params = { user: { username: "bad", password: "Password123" } }
      post "/auth/register", params: params
      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body).to have_key("email")
    end

    it "fails with validation errors when email format invalid" do
      params = { user: { username: "bad2", email: "not-an-email", password: "Password123" } }
      post "/auth/register", params: params
      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["email"]).to include("Invalid email format")
    end

    it "fails with validation errors when password too short" do
      params = { user: { username: "shortpwd", email: "shortpwd@example.com", password: "short" } }
      post "/auth/register", params: params
      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body).to have_key("password")
    end

    it "fails with validation errors when email already taken" do
      existing = User.create!(username: "dupe", email: "dupe@example.com", password: "Password123")
      params = { user: { username: "dupe2", email: existing.email, password: "Password123" } }
      post "/auth/register", params: params
      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["email"]).to be_present
    end

    it "creates a session for the newly registered user" do
      params = { user: { username: "sessu", email: "sessu@example.com", password: "Password123" } }
      post "/auth/register", params: params
      body = JSON.parse(response.body)
      jti = JWTUtils.decode_access(body["access_token"])[0]["jti"]
      session = Session.find_by(jti: jti)
      expect(session).to be_present
      expect(session.user_id).to eq(body["user_id"])
      expect(session.device_id).to be_nil
    end
  end
end
