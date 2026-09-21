module V1
  # Where todos live: rows, not code (TodoBackend). People only. A backend's
  # key goes in and never comes out: responses say `key: "set"` or name the
  # env var that holds it.
  #
  # GET    /v1/todo_backends                  those visible at this clearance, disabled ones included
  # GET    /v1/todo_backends/:name
  # POST   /v1/todo_backends { name, kind, realm?, owner?, primary?, enabled?, config: { url, key | key_env, addr? } }
  # PATCH  /v1/todo_backends/:name            the same; config merges, a null removes a key
  # DELETE /v1/todo_backends/:name            forgets the backend; the todos stay where they live
  # POST   /v1/todo_backends/:name/check      → { backend, reachable, ... } or { reachable: false, error }
  class TodoBackendsController < ApplicationController
    before_action :require_trusted!

    # A name held by a backend above this request's clearance passes the
    # model's uniqueness check (RLS hides the row) and trips the index.
    rescue_from ActiveRecord::RecordNotUnique do
      render json: { error: "Validation failed: Name has already been taken" }, status: :unprocessable_entity
    end

    def index
      render json: TodoBackend.includes(:principal).order(:name).map(&:as_json)
    end

    def show
      render json: backend.as_json
    end

    def create
      row = TodoBackend.new(backend_params)
      row.principal ||= Current.principal
      row.realm = requested_realm
      row.save!
      render json: row.as_json, status: :created
    end

    def update
      backend.assign_attributes(backend_params)
      backend.realm = requested_realm if params[:realm].present?
      backend.save!
      render json: backend.as_json
    end

    def destroy
      backend.destroy!
      head :no_content
    end

    # Asks the backend how it is. 200 either way: unreachable is an answer.
    def check
      render json: { backend: backend.name }.merge(backend.adapter.check)
    rescue Todos::Error => e
      render json: { backend: backend.name, reachable: false, error: e.message }
    end

    private

    def backend
      @backend ||= TodoBackend.find_by!(name: params[:name])
    end

    def backend_params
      params.permit(:name, :kind, :enabled, :primary).to_h.tap do |h|
        h[:principal] = Principal.find_by!(name: params[:owner]) if params[:owner].present?
        h[:config] = merged_config if params.key?(:config)
      end
    end

    # A PATCH changes the keys it names. Setting a key drops the key_env and
    # the other way round, so swapping one for the other is one call.
    def merged_config
      given = (hash_param(:config) || {}).stringify_keys
      current = (@backend&.config || {}).dup
      current.delete("key_env") if given["key"].present?
      current.delete("key") if given["key_env"].present?
      current.merge(given).compact
    end
  end
end
