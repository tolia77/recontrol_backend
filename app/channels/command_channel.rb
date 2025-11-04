class CommandChannel < ApplicationCable::Channel
  def subscribed
    if connection.client_type == "desktop"
      stream_from "device_#{connection.current_device.id}"
    else
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
      status = data["status"]
      result = data["result"]
      error = data["error"]
      response_payload = {
        id: id,
        status: status,
      }
      response_payload[:result] = result if result
      response_payload[:error] = error if error
      ActionCable.server.broadcast(
        "user_#{connection.current_user.id}_to_#{connection.current_device.id}",
        response_payload
      )
    end
  end
end
