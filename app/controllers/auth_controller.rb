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
      client_type = params[:client_type] || "web"
      session = Session.new(user: @user, client_type: client_type)
      if session.save
        access_token = JWTUtils.encode_access(
          { sub: @user.id, jti: session.jti, session_key: session.session_key, exp: ACCESS_EXP_MIN.minutes.from_now.to_i }
        )
        refresh_token = JWTUtils.encode_refresh(
          { sub: @user.id, jti: session.jti, session_key: session.session_key, exp: session.expires_at.to_i }
        )
        set_auth_cookies(access_token, refresh_token)
        render json: { user_id: @user.id, access_token: access_token, refresh_token: refresh_token, user: @user.as_json(except: [:password_digest]) }, status: :created
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
    refresh_token = params[:refresh_token].to_s.split.last || cookies.encrypted[:refresh_token]
    begin
      decoded = JWTUtils.decode_refresh(refresh_token)
      user_id = decoded[0]["sub"]
      jti = decoded[0]["jti"]
      session_key = decoded[0]["session_key"]
      p "DECODED DATA:"
      p user_id
      p jti
      p session_key

      session = Session.find_by(user_id: user_id, jti: jti, session_key: session_key)
      p "OLD SESSION: #{session.inspect}"
      if session
        # DISABLE FOR NOW
        if session.status == "revoked"
          Session.where(user_id: user_id).update_all(status: "revoked")
          render json: { error: "Session revoked" }, status: :unauthorized
        else
          if session.expires_at > Time.current
            session.update(status: "revoked")
            new_session = Session.new(user_id: user_id, device_id: session.session_key)
            if new_session.save
              p "NEW SESSION: #{new_session.inspect}"
              access_token = JWTUtils.encode_access(
                { sub: user_id, jti: new_session.jti, session_key: new_session.session_key, exp: ACCESS_EXP_MIN.minutes.from_now.to_i }
              )
              refresh_token = JWTUtils.encode_refresh(
                { sub: user_id, jti: new_session.jti, session_key: new_session.session_key, exp: new_session.expires_at.to_i }
              )
              set_auth_cookies(access_token, refresh_token)
              render json: { access_token: access_token, refresh_token: refresh_token }, status: :ok
            else
              render json: { error: "Failed to create new session" }, status: :internal_server_error
            end
          else
            render json: { error: "Session expired or not found" }, status: :unauthorized
          end
        end
      else
        render json: { error: "Session not found" }, status: :unauthorized
      end
    rescue JWT::DecodeError
      render json: { error: "Invalid refresh token" }, status: :unauthorized
    end
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
