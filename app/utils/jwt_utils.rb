# frozen_string_literal: true

module JWTUtils
  module_function

  def encode_access(payload)
    JWT.encode(payload, ENV["JWT_ACCESS_SECRET"], "HS256")
  end

  def decode_access(token)
    JWT.decode(token, ENV["JWT_ACCESS_SECRET"], true, { algorithm: "HS256" })
  end

  def encode_refresh(payload)
    JWT.encode(payload, ENV["JWT_REFRESH_SECRET"], "HS256")
  end

  def decode_refresh(token)
    JWT.decode(token, ENV["JWT_REFRESH_SECRET"], true, { algorithm: "HS256" })
  end
end
