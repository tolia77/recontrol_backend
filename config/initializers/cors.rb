Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(
      "127.0.0.1:5175",
      "localhost:5175",
      "api.kokhan.me",
      "kokhan.me",
      /.*\.kokhan\.me/
    )

    resource "*",
             headers: :any,
             methods: [:get, :post, :put, :patch, :delete, :options, :head],
             credentials: true,
             expose: ['Authorization'] # Important for WebSocket auth
  end
end