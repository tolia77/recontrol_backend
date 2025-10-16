class AuthController < ApplicationController
  ACCESS_EXP_MIN = ENV["JWT_ACCESS_EXPIRATION_MINUTES"].to_i
  REFRESH_EXP_DAYS = ENV["JWT_REFRESH_EXPIRATION_DAYS"].to_i
  def login
    email = params[:email]
    password = params[:password]
    client_type = params[:client_type] || "web"
    user = User.find_by(email: email)
    if user&.authenticate(password)
      session = Session.new(user: user, client_type: client_type)
      if session.save
        access_token = JWTUtils.encode_access(
          {
            sub: user.id,
            device_id: session.device_id,
            jti: session.jti,
            session_key: session.session_key,
            exp: ACCESS_EXP_MIN.minutes.from_now.to_i
          }
        )
        refresh_token = JWTUtils.encode_refresh(
          {
            sub: user.id,
            device_id: session.device_id,
            jti: session.jti,
            session_key: session.session_key,
            exp: session.expires_at.to_i
          }
        )
        set_auth_cookies(access_token, refresh_token)
        render json: { user_id: user.id, access_token: access_token, refresh_token: refresh_token }, status: :ok
      else
        render json: { error: "Failed to create session" }, status: :internal_server_error
      end
    else
      render json: { error: "Invalid email or password" }, status: :unauthorized
    end
  end

  def register
  end

  def logout
  end

  def refresh
  end

  private
  def user_params
    params.require(:user).permit(:email, :password, :username)
  end
  def set_auth_cookies(access_token, refresh_token)
    cookies.encrypted[:access_token] = {
      value: access_token,
      httponly: true,
      secure: ENV["USE_SECURE_COOKIES"] == "true",
      same_site: :none,
      expires: ACCESS_EXP_MIN.minutes.from_now
    }

    cookies.encrypted[:refresh_token] = {
      value: refresh_token,
      httponly: true,
      secure: ENV["USE_SECURE_COOKIES"] == "true",
      same_site: :none,
      expires: REFRESH_EXP_DAYS.days.from_now
    }
  end
end
