# frozen_string_literal: true

module Authentication
  extend ActiveSupport::Concern

  # Centralized authorization logic used by both controllers and ActionCable
  def self.authorize_request(request:, cookies:, params: nil)
    Rails.logger.info "[Auth] Starting authorization"

    token = extract_token(request, cookies, params)

    unless token
      Rails.logger.warn "[Auth] Authorization failed: missing_token"
      return { authorized: false, reason: "missing_token" }
    end

    validate_token(token)
  end

  def self.extract_token(request, cookies, params)
    header_token = extract_header_token(request)
    cookie_token = extract_cookie_token(cookies)
    param_token = extract_param_token(params)

    Rails.logger.debug "[Auth] Token sources present: header=#{header_token.present?} cookie=#{cookie_token.present?} param=#{param_token.present?}"

    header_token || cookie_token || param_token
  end

  def self.extract_header_token(request)
    request.headers["Authorization"]&.split(" ")&.last
  end

  def self.extract_cookie_token(cookies)
    return nil unless cookies.respond_to?(:encrypted)

    cookies.encrypted[:access_token]
  rescue StandardError => e
    Rails.logger.warn "[Auth] Encrypted cookies unavailable: #{e.class}: #{e.message}"
    nil
  end

  def self.extract_param_token(params)
    return nil unless params

    params[:access_token]&.split(" ")&.last
  end

  def self.validate_token(token)
    payload = JWTUtils.decode_access(token)[0]
    Rails.logger.debug "[Auth] Decoded payload: sub=#{payload["sub"]} jti=#{payload["jti"]} session_key=#{payload["session_key"]}"

    session = find_active_session(payload)

    if session.nil?
      Rails.logger.warn "[Auth] Authorization failed: session_not_found"
      return { authorized: false, reason: "session_not_found" }
    end

    if session_expired?(session)
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
  rescue StandardError => e
    Rails.logger.error "[Auth] Authorization failed: unexpected_error - #{e.class}: #{e.message}"
    { authorized: false, reason: "unexpected_error" }
  end

  def self.find_active_session(payload)
    Session.find_by(
      user_id: payload["sub"],
      jti: payload["jti"],
      session_key: payload["session_key"],
      status: "active"
    )
  end

  def self.session_expired?(session)
    session.expires_at.nil? || session.expires_at <= Time.current
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Instance Methods for Controllers
  # ──────────────────────────────────────────────────────────────────────────────

  def authorized?
    authorization_result[:authorized]
  end

  def current_user
    return nil unless authorization_result[:authorized]

    authorization_result[:session].user
  end

  private

  # Cache authorization result for the duration of the request
  def authorization_result
    @authorization_result ||= begin
      result = Authentication.authorize_request(request: request, cookies: cookies)
      Rails.logger.info "[Auth] authorized? => #{result[:authorized]} reason=#{result[:reason]}"
      result
    end
  end
end
