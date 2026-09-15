Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  namespace :v1 do
    resources :completions, only: %i[create show]
    resources :conversations, only: %i[index create show] do
      resources :branches, only: %i[index create update], param: :name
      resource :chat, only: :create, controller: "chats"
      resources :events, only: :create
      get "nodes/:hash/siblings", to: "nodes#siblings"
    end
    resources :personas, param: :key, only: %i[index show create update] do
      post :import, on: :collection
    end
    resources :presets, param: :key, only: %i[index show create update destroy]
    resources :snapshots, only: :show
    get "models", to: "models#index"
    get "usage", to: "usage#show"

    # The sentinel (SENTINEL.md): where external agents ask.
    namespace :sentinel do
      resources :requests, only: %i[index show create] do
        post :decide, on: :member
      end
      resources :capabilities, only: %i[index show create update destroy], param: :name, constraints: { name: /[^\/]+/ }
      resources :policies, only: %i[index create update destroy]
    end
    resources :missions, only: %i[index show create] do
      post :lease, on: :collection
      member do
        post :heartbeat
        post :complete
        post :fail
        post :cancel
      end
    end
  end
end
