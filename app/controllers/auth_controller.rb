class AuthController < ApplicationController
  ACCESS_EXP_MIN = ENV["JWT_ACCESS_EXPIRATION_MINUTES"].to_i
  REFRESH_EXP_DAYS = ENV["JWT_REFRESH_EXPIRATION_DAYS"].to_i

  def login
    email = params[:email]
    password = params[:password]
    client_type = params[:client_type] || "web"
    device_id = params[:device_id]
    device_name = params[:device_name]
    @user = User.find_by(email: email)
    if @user&.authenticate(password)
      if client_type == "desktop"
        if device_id.present?
          @device = Device.find(device_id)
          unless @device&.user == @user
            render json: { error: "Device does not belong to user" }, status: :unauthorized
            return
          end
        else
          @device = Device.new(user: @user, name: device_name)
          unless @device.save
            render json: @device.errors, status: :unprocessable_entity
            return
          end
        end
      end

      # Changed: attach device to session only for desktop clients
      session = if client_type == "desktop"
                  Session.new(user: @user, client_type: client_type, device: @device)
                else
                  Session.new(user: @user, client_type: client_type)
                end

      if session.save
        access_payload = {
          sub: @user.id,
          jti: session.jti,
          session_key: session.session_key,
          exp: ACCESS_EXP_MIN.minutes.from_now.to_i
        }
        refresh_payload = {
          sub: @user.id,
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

        set_auth_cookies(access_token, refresh_token)
        res = { user_id: @user.id, access_token: access_token, refresh_token: refresh_token }
        res["device_id"] = @device.id if @device
        render json: res, status: :ok
      else
        render json: { error: "Failed to create session" }, status: :internal_server_error
      end
    else
      render json: { error: "Invalid email or password" }, status: :unauthorized
    end
  end

  def register
    @user = User.new(user_params)
    if @user.save
      session = Session.new(user: user)
      if session.save
        access_token = JWTUtils.encode_access(
          { sub: user.id, jti: session.jti, session_key: session.session_key, exp: ACCESS_EXP_MIN.minutes.from_now.to_i }
        )
        refresh_token = JWTUtils.encode_refresh(
          { sub: user.id, jti: session.jti, session_key: session.session_key, exp: session.expires_at.to_i }
        )
        set_auth_cookies(access_token, refresh_token)
        render json: { user_id: user.id, access_token: access_token, refresh_token: refresh_token, user: user.as_json(except: [:password_digest]) }, status: :created
      else
        @user.destroy
        render json: { error: "Failed to create session" }, status: :internal_server_error
      end
    else
      render json: @user.errors, status: :unprocessable_entity
    end
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
