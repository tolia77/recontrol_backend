# frozen_string_literal: true

module Authentication
  extend ActiveSupport::Concern

  def authorized?
    access_token = request.headers["Authorization"]&.split(" ")&.last || cookies.encrypted[:access_token]
    p "ACCESS TOKEN: #{access_token}"
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
      p "ACCESS PAYLOAD: #{access_payload}"
      p "SESSION: #{session.inspect}"
      session.present? && session.expires_at > Time.current
    rescue JWT::DecodeError, JWT::ExpiredSignature
      p "Token decode error or expired signature"
      false
    end
  end

  def current_user
    return unless authorized?

    access_token = request.headers["Authorization"]&.split(" ")&.last || cookies.encrypted[:access_token]
    begin
      payload = JWTUtils.decode_access(access_token)
      User.find_by(id: payload[0]["sub"])
    rescue JWT::DecodeError, JWT::ExpiredSignature
      nil
    end
  end
end
