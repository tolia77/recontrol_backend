module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user, :client_type, :current_device

    def connect
      token = request.params[:access_token]&.split(" ")&.last
      p token
      reject_unauthorized_connection unless token
      payload = JWTUtils.decode_access(token)[0]
      session = Session.find_by(
        user_id: payload["sub"],
        jti: payload["jti"],
        session_key: payload["session_key"],
        status: "active"
      )

      reject_unauthorized_connection unless session && session.expires_at && session.expires_at > Time.current

      self.current_user = session.user
      self.current_device = session.device
      self.client_type = session.client_type

      # Set desktop device status to active while connected
      if client_type == "desktop" && current_device
        current_device.update(status: "active")
      end
    rescue JWT::DecodeError, JWT::ExpiredSignature
      reject_unauthorized_connection
    end

    # When a connection is closed, update desktop device last seen and mark inactive.
    def disconnect
      # Only handle desktop client_type; do nothing for web
      if client_type == "desktop" && current_device
        current_device.update(
          last_active_at: Time.current,
          status: "inactive"
        )
      end
    end
  end
end
