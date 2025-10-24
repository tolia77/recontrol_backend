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
    rescue JWT::DecodeError, JWT::ExpiredSignature
      reject_unauthorized_connection
    end
  end
end
