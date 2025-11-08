class CommandChannel < ApplicationCable::Channel
  # Command prefix to permissions_group attribute mapping
  PERMISSION_PREFIX_MAP = {
    'keyboard.' => :access_keyboard,
    'mouse.' => :access_mouse,
    'terminal.' => :access_terminal,
    'screen.' => :see_screen, # screen.start / screen.stop ("screen.frame" originates from desktop and is forwarded back)
    'power.' => :manage_power
  }.freeze

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

      # If user is not the owner, enforce permissions based on command prefix
      unless connection.target_device.user_id == connection.current_user.id
        unless command_allowed_for_shared_user?(command)
          Rails.logger.info "[Channel] Blocking command '#{command}' for user_id=#{connection.current_user.id} device_id=#{connection.target_device.id}"
          return # Do not forward
        end
      end

      ActionCable.server.broadcast("device_#{connection.target_device.id}", {
        from: connection.current_user.username,
        id: id,
        command: command,
        payload: payload
      })
    elsif connection.client_type == "desktop"
      command = data["command"]

      # Forward any screen.* messages (e.g., screen.frame, screen.frame_batch) to the frontend as-is
      if command && command.start_with?("screen.")
        ActionCable.server.broadcast(
          "user_#{connection.current_user.id}_to_#{connection.current_device.id}",
          data
        )
        return
      end

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

  private

  def command_allowed_for_shared_user?(command)
    return false if command.nil?

    prefix_entry = PERMISSION_PREFIX_MAP.find { |prefix, _attr| command.start_with?(prefix) }
    return false unless prefix_entry

    _prefix, permission_attr = prefix_entry

    # Load the device_share with permissions_group
    share = DeviceShare.includes(:permissions_group).find_by(user_id: connection.current_user.id, device_id: connection.target_device.id)
    return false unless share&.permissions_group

    share.permissions_group.public_send(permission_attr)
  end
end
