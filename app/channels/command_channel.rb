# app/channels/command_channel.rb
class CommandChannel < ApplicationCable::Channel
  def subscribed
    if connection.client_type == "desktop"
      stream_from "device_#{connection.current_device.id}"
    else
      stream_from "user_#{connection.current_user.id}"
    end
  end

  def receive(data)
    if connection.client_type == "web"
      device = connection.current_user.devices.find_by(id: data["device_id"])
      return unless device

      ActionCable.server.broadcast("device_#{device.id}", {
        from: connection.current_user.username,
        command: data["command"],
        payload: data["payload"]
      })
    elsif connection.client_type == "desktop"
      # send back to web clients
      ActionCable.server.broadcast("user_#{connection.current_user.id}", {
        from: connection.current_device.name,
        command: data["command"],
        payload: data["payload"]
      })
    end
  end
end
