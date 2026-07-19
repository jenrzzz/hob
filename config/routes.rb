Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :v1 do
    resources :conversations, only: %i[index create show] do
      resources :branches, only: %i[index create update], param: :name
      resource :chat, only: :create, controller: "chats"
      get "nodes/:hash/siblings", to: "nodes#siblings"
    end
    resources :personas, param: :key, only: %i[index show create update]
    resources :presets, param: :key, only: %i[index show create update destroy]
    resources :snapshots, only: :show
    get "models", to: "models#index"
  end
end
