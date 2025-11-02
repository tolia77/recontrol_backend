# This channel is dedicated to relaying WebRTC signaling messages (offers, answers, candidates)
# between the "web" (React) client and the "desktop" (WPF) client.
class WebRtcChannel < ApplicationCable::Channel
  # The subscription logic is identical to your CommandChannel.
  # It sets up a private "stream" for each client to listen on.
  def subscribed
    if connection.client_type == "desktop"
      # The desktop app listens on its own unique device channel
      stream_from "webrtc_device_#{connection.current_device.id}"
    else
      # The web app listens on a channel unique to the device it's targeting
      stream_from "webrtc_user_#{connection.current_user.id}_to_#{connection.target_device.id}"
    end
  end

  # This is the core signaling relay.
  # When a client (React or WPF) performs("signal", data),
  # we relay that data to the *other* client.
  def receive(data)
    # The payload is expected to be a WebRTC signaling message
    # (e.g., { type: 'offer', sdp: '...' } or { type: 'ice_candidate', ... })
    payload = data["payload"]

    if connection.client_type == "web"
      # A message from the "web" client (React)
      # Relay it to the "desktop" app's (WPF) private stream
      ActionCable.server.broadcast("webrtc_device_#{connection.target_device.id}", {
        from: connection.current_user.username,
        payload: payload
      })
    elsif connection.client_type == "desktop"
      # A message from the "desktop" client (WPF)
      # Relay it to the "web" app's (React) private stream
      ActionCable.server.broadcast(
        "webrtc_user_#{connection.current_user.id}_to_#{connection.current_device.id}",
        {
          from: connection.current_device.name,
          payload: payload
        }
      )
    end
  end

  def unsubscribed
    # Any cleanup logic can go here
  end
end
