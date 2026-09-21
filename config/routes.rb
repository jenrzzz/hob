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
    resources :prices, only: %i[index show update destroy], param: :model, constraints: { model: /[^\/]+/ }
    get "usage", to: "usage#show"
    # Phones running the companion app (clients/ios): where people are pinged.
    resources :devices, only: %i[index create destroy], param: :token do
      post :ping, on: :member
    end

    # Todos (TODOS.md). A todo's id is "<backend>:<native id>": colons, maybe dots.
    resources :todos, only: %i[index show create update destroy], constraints: { id: /[^\/]+/ } do
      member do
        post :complete
        post :reopen
        post :drop
      end
    end
    resources :todo_lists, only: :index
    resources :todo_backends, only: %i[index show create update destroy], param: :name, constraints: { name: /[^\/]+/ } do
      post :check, on: :member
    end

    # The sentinel (SENTINEL.md): where external agents ask.
    namespace :sentinel do
      resources :requests, only: %i[index show create] do
        post :decide, on: :member
      end
      resources :petitions, only: %i[index show create] do
        post :decide, on: :member
      end
      resources :capabilities, only: %i[index show create update destroy], param: :name, constraints: { name: /[^\/]+/ }
      resources :policies, only: %i[index create update destroy]
    end
    # The ward (WARD.md): checks post reports; people read findings.
    namespace :ward do
      post "runs", action: :create_run
      get "runs", action: :runs
      get "status", action: :status
      get "findings", action: :findings
      post "findings/:id/ack", action: :ack
      post "findings/:id/unack", action: :unack
      get "notes", action: :notes
      post "notes", action: :create_note
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
