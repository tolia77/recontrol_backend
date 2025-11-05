module AuthHelpers
  def sign_in_user(user = nil, client_type: "web", device: nil)
    user ||= User.create!(username: "user_#{SecureRandom.hex(3)}", email: "user_#{SecureRandom.hex(3)}@ex.com", password: "Password123")
    if client_type == "desktop"
      device ||= Device.create!(user: user, name: "Desktop #{SecureRandom.hex(2)}")
    end
    session = Session.create!(user: user, client_type: client_type, device: device)

    access_payload = {
      sub: user.id,
      jti: session.jti,
      session_key: session.session_key,
      exp: AuthController::ACCESS_EXP_MIN.minutes.from_now.to_i
    }
    refresh_payload = {
      sub: user.id,
      jti: session.jti,
      session_key: session.session_key,
      exp: session.expires_at.to_i
    }
    if client_type == "desktop"
      access_payload[:device_id] = session.device_id
      refresh_payload[:device_id] = session.device_id
    end

    access_token = JWTUtils.encode_access(access_payload)
    refresh_token = JWTUtils.encode_refresh(refresh_payload)

    {
      user: user,
      device: device,
      session: session,
      access_token: access_token,
      refresh_token: refresh_token
    }
  end

  def auth_headers(access_token, refresh_token)
    {
      'Authorization' => "#{access_token}",
      'Refresh-Token' => "#{refresh_token}"
    }
  end

  def set_auth_cookies(cookies, access_token, refresh_token)
    cookies.encrypted[:access_token] = {
      value: access_token,
      httponly: true,
      secure: Rails.env.production?,
      same_site: :lax,
      expires: AuthController::ACCESS_EXP_MIN.minutes.from_now
    }

    cookies.encrypted[:refresh_token] = {
      value: refresh_token,
      httponly: true,
      secure: Rails.env.production?,
      same_site: :lax,
      expires: AuthController::REFRESH_EXP_DAYS.days.from_now
    }
  end
end
