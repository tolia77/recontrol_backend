# frozen_string_literal: true

module Authentication
  extend ActiveSupport::Concern

  # Centralized authorization logic used by both controllers and ActionCable
  def self.authorize_request(request:, cookies:, params: nil)
    Rails.logger.info "[Auth] Starting authorization"

    # Extract token from header, encrypted cookie (if available), or params
    auth_header = request.headers["Authorization"]
    header_token = auth_header&.split(" ")&.last
    cookie_token = nil
    begin
      cookie_token = cookies.encrypted[:access_token] if cookies.respond_to?(:encrypted)
    rescue => e
      Rails.logger.warn "[Auth] Encrypted cookies unavailable: #{e.class}: #{e.message}"
    end
    param_token = params && params[:access_token]
    param_token = param_token&.split(" ")&.last if param_token

    token = header_token || cookie_token || param_token

    Rails.logger.debug "[Auth] Token sources present: header=#{header_token.present?} cookie=#{cookie_token.present?} param=#{param_token.present?}"

    unless token
      Rails.logger.warn "[Auth] Authorization failed: missing_token"
      return { authorized: false, reason: "missing_token" }
    end

    begin
      payload = JWTUtils.decode_access(token)[0]
      Rails.logger.debug "[Auth] Decoded payload: sub=#{payload["sub"]} jti=#{payload["jti"]} session_key=#{payload["session_key"]}"

      session = Session.find_by(
        user_id: payload["sub"],
        jti: payload["jti"],
        session_key: payload["session_key"],
        status: "active"
      )

      if session.nil?
        Rails.logger.warn "[Auth] Authorization failed: session_not_found"
        return { authorized: false, reason: "session_not_found" }
      end

      if !session.expires_at || session.expires_at <= Time.current
        Rails.logger.warn "[Auth] Authorization failed: session_expired at #{session.expires_at}"
        return { authorized: false, reason: "session_expired" }
      end

      Rails.logger.info "[Auth] Authorization success for user_id=#{session.user_id}"
      { authorized: true, payload: payload, session: session }
    rescue JWT::ExpiredSignature
      Rails.logger.warn "[Auth] Authorization failed: token_expired"
      { authorized: false, reason: "token_expired" }
    rescue JWT::DecodeError => e
      Rails.logger.error "[Auth] Authorization failed: token_invalid - #{e.class}: #{e.message}"
      { authorized: false, reason: "token_invalid" }
    rescue => e
      Rails.logger.error "[Auth] Authorization failed: unexpected_error - #{e.class}: #{e.message}"
      { authorized: false, reason: "unexpected_error" }
    end
  end

  def authorized?
    result = Authentication.authorize_request(request: request, cookies: cookies)
    Rails.logger.info "[Auth] authorized? => #{result[:authorized]} reason=#{result[:reason]}"
    result[:authorized]
  end

  def current_user
    result = Authentication.authorize_request(request: request, cookies: cookies)
    return result[:session].user if result[:authorized]
    nil
  end
end
