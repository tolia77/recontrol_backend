class CommandChannel < ApplicationCable::Channel
  def subscribed
    if connection.client_type == "desktop"
      unless connection.current_device && connection.current_device.user_id == connection.current_user.id
        Rails.logger.warn "[Channel] Rejecting desktop subscription: device does not belong to user"
        reject
        return
      end
      stream_from "device_#{connection.current_device.id}"
    else
      device = connection.target_device
      user = connection.current_user
      unless device && user && (device.user_id == user.id || DeviceShare.exists?(user_id: user.id, device_id: device.id))
        Rails.logger.warn "[Channel] Rejecting web subscription: access denied for user_id=#{user&.id} device_id=#{device&.id}"
        reject
        return
      end
      stream_from "user_#{connection.current_user.id}_to_#{connection.target_device.id}"
    end
  end

  def receive(data)
    id = data["id"]

    if connection.client_type == "web"
      command = data["command"]
      payload = data["payload"]
      ActionCable.server.broadcast("device_#{connection.target_device.id}", {
        from: connection.current_user.username,
        id: id,
        command: command,
        payload: payload
      })
    elsif connection.client_type == "desktop"
      command = data["command"]
      status = data["status"]
      result = data["result"]
      error = data["error"]
      if command && command == "screen.frame"
        response_payload = {
          command: command,
          payload: data["payload"]
        }
      else
        response_payload = {
          id: id,
          status: status,
        }
      end
      response_payload[:result] = result if result
      response_payload[:error] = error if error
      ActionCable.server.broadcast(
        "user_#{connection.current_user.id}_to_#{connection.current_device.id}",
        response_payload
      )
    end
  end
end
