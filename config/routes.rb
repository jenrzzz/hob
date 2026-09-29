Rails.application.routes.draw do
  get "up" => "rails/health#show", as: :rails_health_check

  # Admin pages (a person's browser session; the API below takes bearer keys).
  # POST, not DELETE: API-only Rails has no Rack::MethodOverride for forms.
  get "login", to: "sessions#new"
  match "auth/:provider/callback", to: "sessions#create", via: %i[get post]
  get "auth/failure", to: "sessions#failure"
  # The companion app signing in (clients/ios): a browser sheet, then a key.
  get "app/sign_in", to: "app_sign_ins#new"
  post "app/sign_in", to: "app_sign_ins#create"
  post "logout", to: "sessions#destroy"
  namespace :admin do
    root "principals#index"
    resources :principals, only: :create do
      resources :keys, only: :create
    end
    get "sentinel", to: "sentinel#index"
    post "sentinel/requests/:id/decide", to: "sentinel#decide_request", as: :decide_sentinel_request
    post "sentinel/petitions/:id/decide", to: "sentinel#decide_petition", as: :decide_sentinel_petition
    get "grants", to: "grants#index"
    get "grants/:id", to: "grants#show", as: :grant
    post "grants/:id", to: "grants#update", as: :update_grant
    get "gofer_keys", to: "gofer_keys#new", as: :gofer_keys
    post "gofer_keys", to: "gofer_keys#update"
    resources :keys, only: [] do
      member do
        post :rotate
        post :revoke
      end
    end
  end

  namespace :v1 do
    resources :completions, only: %i[create show]
    resources :app_sessions, only: :create
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

    # Browsing (BROWSE.md): the household's browsers, and sessions in them.
    resources :browsers, only: %i[index show create update destroy], param: :name, constraints: { name: /[^\/]+/ } do
      post :check, on: :member
    end
    resources :browse_sessions, only: %i[index show create destroy] do
      post :actions, on: :member, action: :act
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
      # The same MCP server for an agent's key (CLAUDE_CODE.md, "Agents"):
      # its tools are what policy grants it, and each call is a request.
      post "mcp", to: "mcp#create"
      match "mcp", to: "mcp#unsupported", via: %i[get delete]
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
    # hob as an MCP server (CLAUDE_CODE.md): a person's assistant's tools.
    post "mcp", to: "mcp#create"
    match "mcp", to: "mcp#unsupported", via: %i[get delete]

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
