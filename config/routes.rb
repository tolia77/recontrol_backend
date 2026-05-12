Rails.application.routes.draw do
  resources :permissions_groups
  get "device_shares/me", to: "device_shares#me"
  resources :device_shares
  mount ActionCable.server => "/cable"
  get "devices/me", to: "devices#me"
  resources :devices
  resources :users
  namespace :admin do
    get "ai_usage", to: "ai_usage#index"
  end

  post "auth/login"
  post "auth/register"
  post "auth/logout"
  post "auth/refresh"

  get "turn_credentials", to: "turn_credentials#show"
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  # root "posts#index"
end
