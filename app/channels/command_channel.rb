# frozen_string_literal: true

class CommandChannel < ApplicationCable::Channel
  # Command prefix to permissions_group attribute mapping
  PERMISSION_PREFIX_MAP = {
    "keyboard." => :access_keyboard,
    "mouse." => :access_mouse,
    "terminal." => :access_terminal,
    "screen." => :see_screen,
    "power." => :manage_power
  }.freeze

  def subscribed
    connection.client_type == "desktop" ? subscribe_desktop : subscribe_web
  end

  def receive(data)
    connection.client_type == "web" ? handle_web_message(data) : handle_desktop_message(data)
  end

  private

  # ──────────────────────────────────────────────────────────────────────────────
  # Subscription Handlers
  # ──────────────────────────────────────────────────────────────────────────────

  def subscribe_desktop
    unless valid_desktop_subscription?
      Rails.logger.warn "[Channel] Rejecting desktop subscription: device does not belong to user"
      reject
      return
    end

    stream_from device_stream(connection.current_device)
  end

  def subscribe_web
    unless valid_web_subscription?
      Rails.logger.warn "[Channel] Rejecting web subscription: access denied for " \
                        "user_id=#{connection.current_user&.id} device_id=#{connection.target_device&.id}"
      reject
      return
    end

    stream_from user_to_device_stream(connection.target_device)
    connection.target_device.update!(status: "used")
  end

  def valid_desktop_subscription?
    connection.current_device &&
      connection.current_device.user_id == connection.current_user.id
  end

  def valid_web_subscription?
    device = connection.target_device
    user = connection.current_user

    return false unless device && user

    device_owner?(device, user) || device_shared_with?(device, user)
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Message Handlers
  # ──────────────────────────────────────────────────────────────────────────────

  def handle_web_message(data)
    command = data["command"]
    payload = data["payload"]
    message_id = data["id"]

    unless owner_or_allowed_command?(command)
      Rails.logger.info "[Channel] Blocking command '#{command}' for " \
                        "user_id=#{connection.current_user.id} device_id=#{connection.target_device.id}"
      return
    end

    broadcast_to_device(connection.target_device, {
      from: connection.current_user.username,
      id: message_id,
      command: command,
      payload: payload
    })
  end

  def handle_desktop_message(data)
    command = data["command"]

    if screen_command?(command)
      broadcast_screen_data(data)
    else
      broadcast_command_response(data)
    end
  end

  def broadcast_screen_data(data)
    # Remove ActionCable-added metadata before forwarding
    outgoing = data.except("action")

    broadcast_to_user(
      connection.current_user,
      connection.current_device,
      outgoing
    )
  end

  def broadcast_command_response(data)
    response = build_response_payload(data)

    broadcast_to_user(
      connection.current_user,
      connection.current_device,
      response
    )
  end

  def build_response_payload(data)
    {
      id: data["id"],
      status: data["status"]
    }.tap do |payload|
      payload[:result] = data["result"] if data["result"]
      payload[:error] = data["error"] if data["error"]
    end
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Permission Helpers
  # ──────────────────────────────────────────────────────────────────────────────

  def owner_or_allowed_command?(command)
    return true if device_owner?(connection.target_device, connection.current_user)

    command_allowed_for_shared_user?(command)
  end

  def command_allowed_for_shared_user?(command)
    return false if command.nil?

    permission_attr = permission_for_command(command)
    return false unless permission_attr

    share = find_device_share
    return false unless share&.permissions_group

    share.permissions_group.public_send(permission_attr)
  end

  def permission_for_command(command)
    PERMISSION_PREFIX_MAP.find { |prefix, _| command.start_with?(prefix) }&.last
  end

  def find_device_share
    DeviceShare.includes(:permissions_group).find_by(
      user_id: connection.current_user.id,
      device_id: connection.target_device.id
    )
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Device Access Helpers
  # ──────────────────────────────────────────────────────────────────────────────

  def device_owner?(device, user)
    device.user_id == user.id
  end

  def device_shared_with?(device, user)
    DeviceShare.exists?(user_id: user.id, device_id: device.id)
  end

  def screen_command?(command)
    command&.start_with?("screen.")
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Stream Name Generators
  # ──────────────────────────────────────────────────────────────────────────────

  def device_stream(device)
    "device_#{device.id}"
  end

  def user_to_device_stream(device)
    "user_#{device.user_id}_to_#{device.id}"
  end

  # ──────────────────────────────────────────────────────────────────────────────
  # Broadcast Helpers
  # ──────────────────────────────────────────────────────────────────────────────

  def broadcast_to_device(device, payload)
    ActionCable.server.broadcast(device_stream(device), payload)
  end

  def broadcast_to_user(user, device, payload)
    ActionCable.server.broadcast("user_#{user.id}_to_#{device.id}", payload)
  end
end
