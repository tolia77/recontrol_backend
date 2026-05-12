# frozen_string_literal: true

require "faraday"

class TurnCredentialsController < ApplicationController
  before_action :authenticate_user!

  CLOUDFLARE_URL = "https://rtc.live.cloudflare.com/v1/turn/keys"
  CREDENTIAL_TTL_SECONDS = 3600

  # GET /turn_credentials
  def show
    token_id = ENV["CLOUDFLARE_TURN_TOKEN_ID"]
    api_token = ENV["CLOUDFLARE_TURN_API_TOKEN"]

    if token_id.blank? || api_token.blank?
      Rails.logger.error "[TurnCredentials] Cloudflare TURN env vars missing"
      render json: { error: "TURN credentials not configured" }, status: :service_unavailable
      return
    end

    response = Faraday.post(
      "#{CLOUDFLARE_URL}/#{token_id}/credentials/generate-ice-servers",
      { ttl: CREDENTIAL_TTL_SECONDS }.to_json,
      "Authorization" => "Bearer #{api_token}",
      "Content-Type" => "application/json"
    )

    unless response.success?
      Rails.logger.error "[TurnCredentials] Cloudflare API error: status=#{response.status} body=#{response.body}"
      render json: { error: "Failed to mint TURN credentials" }, status: :bad_gateway
      return
    end

    body = JSON.parse(response.body)
    cf_servers = body["iceServers"]

    # Pair cheap public STUN with Cloudflare's relay servers so ICE prefers
    # host/srflx and only falls back to TURN when needed. Cloudflare's
    # generate-ice-servers endpoint returns an array of RTCIceServer dicts;
    # we also accept a single hash for forward-compatibility with the older
    # response shape some Cloudflare account configurations return.
    ice_servers = [ { "urls" => "stun:stun.l.google.com:19302" } ]
    case cf_servers
    when Array then ice_servers.concat(cf_servers)
    when Hash  then ice_servers << cf_servers if cf_servers.any?
    end

    render json: { ice_servers: ice_servers }, status: :ok
  rescue Faraday::Error => e
    Rails.logger.error "[TurnCredentials] Faraday error: #{e.class}: #{e.message}"
    render json: { error: "TURN provider unreachable" }, status: :bad_gateway
  rescue JSON::ParserError => e
    Rails.logger.error "[TurnCredentials] JSON parse error: #{e.message}"
    render json: { error: "TURN provider returned invalid response" }, status: :bad_gateway
  end
end
