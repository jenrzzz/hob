module V1
  # The household's browsers: rows, not code (Browser). People only. A
  # browser's key goes in and never comes out: responses say `key: "set"`
  # or name the env var that holds it.
  #
  # GET    /v1/browsers                  those visible at this clearance, disabled ones included
  # GET    /v1/browsers/:name
  # POST   /v1/browsers { name, kind, realm?, owner?, enabled?, config: { url, key | key_env, addr?, domains? } }
  # PATCH  /v1/browsers/:name            the same; config merges, a null removes a key
  # DELETE /v1/browsers/:name            forgets the browser, its session records with it
  # POST   /v1/browsers/:name/check      → { browser, reachable, ... } or { reachable: false, error }
  class BrowsersController < ApplicationController
    before_action :require_trusted!

    rescue_from ActiveRecord::RecordNotUnique do
      render json: { error: "Validation failed: Name has already been taken" }, status: :unprocessable_entity
    end

    def index
      render json: Browser.includes(:principal).order(:name).map(&:as_json)
    end

    def show
      render json: browser.as_json
    end

    def create
      row = Browser.new(browser_params)
      row.principal ||= Current.principal
      row.realm = requested_realm
      row.save!
      render json: row.as_json, status: :created
    end

    def update
      browser.assign_attributes(browser_params)
      browser.realm = requested_realm if params[:realm].present?
      browser.save!
      render json: browser.as_json
    end

    def destroy
      browser.destroy!
      head :no_content
    end

    # Asks the browser how it is. 200 either way: unreachable is an answer.
    def check
      render json: { browser: browser.name }.merge(browser.adapter.check)
    rescue Browse::Error => e
      render json: { browser: browser.name, reachable: false, error: e.message }
    end

    private

    def browser
      @browser ||= Browser.find_by!(name: params[:name])
    end

    def browser_params
      params.permit(:name, :kind, :enabled).to_h.tap do |h|
        h[:principal] = Principal.find_by!(name: params[:owner]) if params[:owner].present?
        h[:config] = merged_config if params.key?(:config)
      end
    end

    def merged_config
      given = (hash_param(:config) || {}).stringify_keys
      current = (@browser&.config || {}).dup
      current.delete("key_env") if given["key"].present?
      current.delete("key") if given["key_env"].present?
      current.merge(given).compact
    end
  end
end
