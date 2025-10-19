module AuthHelpers
  def sign_in_user(user = nil)
    user ||= FactoryBot.create(:user)
    session = Session.create!(user: user)

    access_token = JWTUtils.encode_access(
      sub: user.id,
      jti: session.jti,
      session_key: session.session_key,
      exp: AuthController::ACCESS_EXP_MIN.minutes.from_now.to_i
    )

    refresh_token = JWTUtils.encode_refresh(
      sub: user.id,
      jti: session.jti,
      session_key: session.session_key,
      exp: session.expires_at.to_i
    )

    {
      user: user,
      session: session,
      access_token: access_token,
      refresh_token: refresh_token
    }
  end

  def auth_headers(access_token, refresh_token)
    {
      'Authorization' => "Bearer #{access_token}",
      'Refresh-Token' => "Bearer #{refresh_token}"
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
