# app/channels/application_cable/connection.rb
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :client_type, :current_device, :target_device

    def connect
      Rails.logger.info "[Cable] connect started"
      result = Authentication.authorize_request(request: request, cookies: cookies, params: request.params)
      Rails.logger.info "[Cable] authorization result: authorized=#{result[:authorized]} reason=#{result[:reason]}"

      reject_unauthorized_connection unless result[:authorized]

      session = result[:session]
      self.current_user = session.user
      self.current_device = session.device
      self.client_type = session.client_type

      Rails.logger.info "[Cable] connected user_id=#{current_user&.id} client_type=#{client_type} device_id=#{current_device&.id}"

      if client_type == "desktop" && current_device
        Rails.logger.info "[Cable] Activating desktop device id=#{current_device.id}"
        current_device.update(status: "active")
      end

      if client_type == "web"
        device_id = request.params[:device_id]
        Rails.logger.info "[Cable] Web client targeting device_id=#{device_id}"
        self.target_device = current_user.devices.find_by(id: device_id)
        unless target_device
          Rails.logger.warn "[Cable] Authorization failed: target_device_not_found for device_id=#{device_id}"
          reject_unauthorized_connection
        end
      end
    end

    def disconnect
      Rails.logger.info "[Cable] disconnect started user_id=#{current_user&.id} client_type=#{client_type} device_id=#{current_device&.id}"
      if client_type == "desktop" && current_device
        current_device.update(
          last_active_at: Time.current,
          status: "inactive"
        )
        Rails.logger.info "[Cable] Deactivated desktop device id=#{current_device.id}"
      end
    end
  end
end
