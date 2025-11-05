require 'rails_helper'

RSpec.describe "Auth", type: :request do
  let(:password) { "Password123" }
  let(:user) { User.create!(username: "tester", email: "tester@example.com", password: password) }

  # Helper to extract the raw JWT part from a possibly Bearer-prefixed token
  def raw_token(token_or_bearer)
    token_or_bearer.to_s.split.last
  end

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

      access_payload = JWTUtils.decode_access(raw_token(body["access_token"]))[0]
      refresh_payload = JWTUtils.decode_refresh(raw_token(body["refresh_token"]))[0]
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

      access_payload = JWTUtils.decode_access(raw_token(body["access_token"]))[0]
      refresh_payload = JWTUtils.decode_refresh(raw_token(body["refresh_token"]))[0]
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

      access_payload = JWTUtils.decode_access(raw_token(body["access_token"]))[0]
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
      # Pass empty device_name to trigger validation error (presence/length)
      post "/auth/login", params: { email: user.email, password: password, client_type: "desktop", device_name: "" }
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

      access_payload = JWTUtils.decode_access(raw_token(body["access_token"]))[0]
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
      jti = JWTUtils.decode_access(raw_token(body["access_token"]))[0]["jti"]
      session = Session.find_by(jti: jti)
      expect(session).to be_present
      expect(session.user_id).to eq(body["user_id"])
      expect(session.device_id).to be_nil
    end
  end

  describe "POST /auth/refresh" do
    it "rotates tokens for web client successfully" do
      post "/auth/login", params: { email: user.email, password: password, client_type: "web" }
      expect(response).to have_http_status(:ok)
      body1 = JSON.parse(response.body)
      refresh1 = body1["refresh_token"]
      payload1 = JWTUtils.decode_refresh(raw_token(refresh1))[0]
      old_jti = payload1["jti"]

      # Use the bearer string exactly as returned
      post "/auth/refresh", headers: { "Refresh-Token" => refresh1 }
      expect(response).to have_http_status(:ok)
      body2 = JSON.parse(response.body)
      access2 = body2["access_token"]
      refresh2 = body2["refresh_token"]

      access_payload2 = JWTUtils.decode_access(raw_token(access2))[0]
      refresh_payload2 = JWTUtils.decode_refresh(raw_token(refresh2))[0]

      expect(access_payload2["device_id"]).to be_nil
      expect(refresh_payload2["jti"]).not_to eq(old_jti)

      old_session = Session.find_by(jti: old_jti)
      new_session = Session.find_by(jti: refresh_payload2["jti"])
      expect(old_session.status).to eq("revoked")
      expect(new_session.status).to eq("active")
      expect(new_session.client_type).to eq("web")
      expect(new_session.device_id).to be_nil
    end

    it "rotates tokens for desktop client and preserves device_id" do
      device = Device.create!(user: user, name: "Work PC")
      post "/auth/login", params: { email: user.email, password: password, client_type: "desktop", device_id: device.id }
      expect(response).to have_http_status(:ok)
      body1 = JSON.parse(response.body)
      refresh1 = body1["refresh_token"]
      payload1 = JWTUtils.decode_refresh(raw_token(refresh1))[0]
      old_jti = payload1["jti"]
      expect(payload1["device_id"]).to eq(device.id)

      post "/auth/refresh", headers: { "Refresh-Token" => refresh1 }
      expect(response).to have_http_status(:ok)
      body2 = JSON.parse(response.body)
      access2 = body2["access_token"]
      refresh2 = body2["refresh_token"]

      access_payload2 = JWTUtils.decode_access(raw_token(access2))[0]
      refresh_payload2 = JWTUtils.decode_refresh(raw_token(refresh2))[0]

      expect(access_payload2["device_id"]).to eq(device.id)
      expect(refresh_payload2["device_id"]).to eq(device.id)

      old_session = Session.find_by(jti: old_jti)
      new_session = Session.find_by(jti: refresh_payload2["jti"])
      expect(old_session.status).to eq("revoked")
      expect(new_session.status).to eq("active")
      expect(new_session.client_type).to eq("desktop")
      expect(new_session.device_id).to eq(device.id)
    end

    it "returns 401 when refresh token is missing" do
      post "/auth/refresh"
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("Invalid refresh token")
    end

    it "returns 401 for invalid refresh token" do
      post "/auth/refresh", params: { refresh_token: "invalid.token" }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("Invalid refresh token")
    end

    it "returns 401 when session is expired" do
      post "/auth/login", params: { email: user.email, password: password, client_type: "web" }
      body = JSON.parse(response.body)
      refresh_token = body["refresh_token"]
      payload = JWTUtils.decode_refresh(raw_token(refresh_token))[0]
      sess = Session.find_by(user_id: payload["sub"], jti: payload["jti"], session_key: payload["session_key"])
      sess.update!(expires_at: 1.minute.ago)

      post "/auth/refresh", headers: { "Refresh-Token" => refresh_token }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("Session expired or not found")
    end

    it "returns 401 when using an already-rotated (revoked) refresh token" do
      post "/auth/login", params: { email: user.email, password: password, client_type: "web" }
      body1 = JSON.parse(response.body)
      refresh1 = body1["refresh_token"]

      # First refresh rotates the session
      post "/auth/refresh", headers: { "Refresh-Token" => refresh1 }
      expect(response).to have_http_status(:ok)

      # Reuse the old refresh token -> revoked
      post "/auth/refresh", headers: { "Refresh-Token" => refresh1 }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("Session revoked")
    end

    it "returns 401 when refresh token device_id does not match session device (tampered token)" do
      device = Device.create!(user: user, name: "Home PC")
      other_device = Device.create!(user: user, name: "Other PC")
      post "/auth/login", params: { email: user.email, password: password, client_type: "desktop", device_id: device.id }
      body = JSON.parse(response.body)
      refresh_token = body["refresh_token"]
      payload = JWTUtils.decode_refresh(raw_token(refresh_token))[0]
      tampered = payload.merge("device_id" => other_device.id)
      tampered_token = JWTUtils.encode_refresh(tampered)

      post "/auth/refresh", headers: { "Refresh-Token" => "Bearer #{tampered_token}" }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("Device mismatch")
    end

    it "returns 401 when session not found for given token data" do
      post "/auth/login", params: { email: user.email, password: password, client_type: "web" }
      body = JSON.parse(response.body)
      refresh_token = body["refresh_token"]
      payload = JWTUtils.decode_refresh(raw_token(refresh_token))[0]

      # Delete the backing session
      Session.find_by(user_id: payload["sub"], jti: payload["jti"], session_key: payload["session_key"])&.destroy!

      post "/auth/refresh", headers: { "Refresh-Token" => refresh_token }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("Session not found")
    end
  end

  describe "POST /auth/logout" do
    it "revokes session when access token provided" do
      post "/auth/login", params: { email: user.email, password: password, client_type: "web" }
      body = JSON.parse(response.body)
      access = body["access_token"]
      payload = JWTUtils.decode_access(raw_token(access))[0]
      session = Session.find_by(jti: payload["jti"])

      # Use the bearer string exactly as returned
      post "/auth/logout", headers: { "Authorization" => access }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to eq("Logged out")

      session.reload
      expect(session.status).to eq("revoked")
    end

    it "revokes session when only refresh token provided" do
      post "/auth/login", params: { email: user.email, password: password, client_type: "web" }
      body = JSON.parse(response.body)
      refresh = body["refresh_token"]
      payload = JWTUtils.decode_refresh(raw_token(refresh))[0]
      session = Session.find_by(jti: payload["jti"])

      post "/auth/logout", headers: { "Refresh-Token" => refresh }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to eq("Logged out")

      session.reload
      expect(session.status).to eq("revoked")
    end

    it "is idempotent (second logout still returns ok)" do
      post "/auth/login", params: { email: user.email, password: password, client_type: "web" }
      body = JSON.parse(response.body)
      access = body["access_token"]

      post "/auth/logout", headers: { "Authorization" => access }
      expect(response).to have_http_status(:ok)

      post "/auth/logout", headers: { "Authorization" => access }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["message"]).to eq("Logged out")
    end

    it "returns 401 when no valid token supplied" do
      post "/auth/logout"
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("Invalid token")
    end

    it "returns 401 when token is invalid" do
      post "/auth/logout", headers: { "Authorization" => "Bearer invalid.token" }
      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to eq("Invalid token")
    end
  end
end
