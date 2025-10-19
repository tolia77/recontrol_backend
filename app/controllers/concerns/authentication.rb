# frozen_string_literal: true

module Authentication
  extend ActiveSupport::Concern

  def authorized?
    if request.headers["X-Service-Token"] == ENV["SERVICE_TOKEN"]
      return true
    end
    access_token = request.headers["Authorization"]&.split(" ")&.last || cookies.encrypted[:access_token]
    refresh_token = request.headers["Refresh-Token"]&.split(" ")&.last || cookies.encrypted[:refresh_token]
    return false unless access_token && refresh_token
    begin
      # Verify access token first (faster check)
      access_payload = JWTUtils.decode_access(access_token)
      user_id = access_payload[0]["sub"]
      jti = access_payload[0]["jti"]
      session_key = access_payload[0]["session_key"]
      session = Session.find_by(
        user_id: user_id,
        jti: jti,
        session_key: session_key,
        status: "active"
      )
      return true if session.present? && session.expires_at > Time.current

      # If access token is invalid, try refresh token
      refresh_payload = JWTUtils.decode_refresh(refresh_token)
      user_id = refresh_payload[0]["sub"]
      jti = refresh_payload[0]["jti"]
      session_key = refresh_payload[0]["session_key"]

      session = Session.find_by(
        user_id: user_id,
        jti: jti,
        session_key: session_key,
        status: "active"
      )

      session.present? && session.expires_at > Time.current
    rescue JWT::DecodeError, JWT::ExpiredSignature
      false
    end
  end

  def current_user
    return unless authorized?

    access_token = cookies.encrypted[:access_token] || request.headers["Authorization"]&.split(" ")&.last
    begin
      payload = JWTUtils.decode_access(access_token)
      User.find_by(id: payload[0]["sub"])
    rescue JWT::DecodeError, JWT::ExpiredSignature
      nil
    end
  end
end
