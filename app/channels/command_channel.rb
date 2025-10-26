class CommandChannel < ApplicationCable::Channel
  def subscribed
    if connection.client_type == "desktop"
      stream_from "device_#{connection.current_device.id}"
    else
      stream_from "user_#{connection.current_user.id}_to_#{connection.target_device.id}"
    end
  end

  def receive(data)
    command = data["command"]
    payload = data["payload"]

    if connection.client_type == "web"
      ActionCable.server.broadcast("device_#{connection.target_device.id}", {
        from: connection.current_user.username,
        command: command,
        payload: payload
      })
    elsif connection.client_type == "desktop"
      ActionCable.server.broadcast(
        "user_#{connection.current_user.id}_to_#{connection.current_device.id}",
        {
          from: connection.current_device.name,
          command: command,
          payload: payload
        }
      )
    end
  end
end
