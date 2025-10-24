# app/channels/command_channel.rb
class CommandChannel < ApplicationCable::Channel
  def subscribed
    if connection.client_type == "desktop"
      stream_from "device_#{connection.current_device.id}"
    else
      stream_from "user_#{connection.current_user.id}_to_#{connection.target_device.id}"
    end
  end

  def receive(data)
    if connection.client_type == "web"
      ActionCable.server.broadcast("device_#{connection.target_device.id}", {
        from: connection.current_user.username,
        command: data["command"],
        payload: data["payload"]
      })
    elsif connection.client_type == "desktop"
      ActionCable.server.broadcast(
        "user_#{connection.current_user.id}_to_#{connection.current_device.id}",
        {
          from: connection.current_device.name,
          command: data["command"],
          payload: data["payload"]
        }
      )
    end
  end
end
