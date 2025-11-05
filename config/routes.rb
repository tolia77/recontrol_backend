Rails.application.routes.draw do
  resources :permissions_groups
  resources :device_shares
  mount ActionCable.server => "/cable"
  resources :devices do
    collection do
      get :me
    end
  end

  post "auth/login"
  post "auth/register"
  post "auth/logout"
  post "auth/refresh"
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  # root "posts#index"
end
