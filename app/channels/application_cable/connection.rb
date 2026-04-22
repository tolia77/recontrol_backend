# frozen_string_literal: true

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :client_type, :current_device, :target_device

    def connect
      Rails.logger.info "[Cable] connect started"

      authorize_connection!
      setup_client_context
    end

    def disconnect
      Rails.logger.info "[Cable] disconnect started user_id=#{current_user&.id} " \
                        "client_type=#{client_type} device_id=#{current_device&.id}"

      case client_type
      when "desktop"
        deactivate_desktop_device
      when "web"
        release_web_device
      end
    end

    private

    # ──────────────────────────────────────────────────────────────────────────────
    # Connection Setup
    # ──────────────────────────────────────────────────────────────────────────────

    def authorize_connection!
      result = Authentication.authorize_request(
        request: request,
        cookies: cookies,
        params: request.params
      )

      Rails.logger.info "[Cable] authorization result: authorized=#{result[:authorized]} reason=#{result[:reason]}"

      reject_unauthorized_connection unless result[:authorized]

      session = result[:session]
      self.current_user = session.user
      self.current_device = session.device
      self.client_type = session.client_type

      Rails.logger.info "[Cable] connected user_id=#{current_user&.id} " \
                        "client_type=#{client_type} device_id=#{current_device&.id}"
    end

    def setup_client_context
      case client_type
      when "desktop"
        activate_desktop_device
      when "web"
        validate_and_set_target_device!
      end
    end

    # ──────────────────────────────────────────────────────────────────────────────
    # Desktop Client Handlers
    # ──────────────────────────────────────────────────────────────────────────────

    def activate_desktop_device
      return unless current_device

      Rails.logger.info "[Cable] Activating desktop device id=#{current_device.id}"
      new_status = web_clients_active?(current_device) ? "used" : "active"
      current_device.update(status: new_status, last_active_at: Time.current)
    end

    def deactivate_desktop_device
      return unless current_device

      current_device.update(
        last_active_at: Time.current,
        status: "inactive"
      )
      Rails.logger.info "[Cable] Deactivated desktop device id=#{current_device.id}"
    end

    # ──────────────────────────────────────────────────────────────────────────────
    # Web Client Handlers
    # ──────────────────────────────────────────────────────────────────────────────

    def validate_and_set_target_device!
      device_id = request.params[:device_id]
      Rails.logger.info "[Cable] Web client targeting device_id=#{device_id}"

      validate_device_id_presence!(device_id)
      device = find_target_device!(device_id)
      validate_device_access!(device)

      self.target_device = device
    end

    def validate_device_id_presence!(device_id)
      return if device_id.present?

      Rails.logger.warn "[Cable] Authorization failed: missing_device_id"
      reject_unauthorized_connection
    end

    def find_target_device!(device_id)
      device = Device.find_by(id: device_id)

      unless device
        Rails.logger.warn "[Cable] Authorization failed: target_device_not_found for device_id=#{device_id}"
        reject_unauthorized_connection
      end

      device
    end

    def validate_device_access!(device)
      return if device_accessible?(device)

      Rails.logger.warn "[Cable] Authorization failed: access_denied " \
                        "for user_id=#{current_user.id} device_id=#{device.id}"
      reject_unauthorized_connection
    end

    def device_accessible?(device)
      device_owner?(device) || device_shared?(device)
    end

    def device_owner?(device)
      device.user_id == current_user.id
    end

    def device_shared?(device)
      DeviceShare.exists?(user_id: current_user.id, device_id: device.id)
    end

    def release_web_device
      return unless target_device&.status == "used"
      return if web_clients_active?(target_device)

      target_device.update!(status: "active")
    end

    # Counts web ActionCable connections targeting the given device, excluding self.
    # Per-process only: assumes a single Puma worker. With multiple workers, use a
    # Redis-backed presence counter instead.
    def web_clients_active?(device)
      ActionCable.server.connections.any? do |conn|
        conn != self &&
          conn.client_type == "web" &&
          conn.target_device&.id == device.id
      end
    end
  end
end
