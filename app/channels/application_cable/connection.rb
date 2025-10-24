# app/channels/application_cable/connection.rb
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :client_type, :current_device, :target_device

    def connect
      token = request.params[:access_token]&.split(" ")&.last
      p token
      reject_unauthorized_connection unless token

      begin
        payload = JWTUtils.decode_access(token)[0]
      rescue JWT::ExpiredSignature
        reject_unauthorized_connection
      end
      p payload
      session = Session.find_by(
        user_id: payload["sub"],
        jti: payload["jti"],
        session_key: payload["session_key"],
        status: "active"
      )
      reject_unauthorized_connection unless session&.expires_at&.> Time.current

      self.current_user = session.user
      self.current_device = session.device
      self.client_type = session.client_type

      if client_type == "desktop" && current_device
        current_device.update(status: "active")
      end

      if client_type == "web"
        device_id = request.params[:device_id]
        self.target_device = current_user.devices.find_by(id: device_id)
        reject_unauthorized_connection unless target_device
      end
    rescue JWT::DecodeError, JWT::ExpiredSignature
      reject_unauthorized_connection
    end

    def disconnect
      if client_type == "desktop" && current_device
        current_device.update(
          last_active_at: Time.current,
          status: "inactive"
        )
      end
    end
  end
end
