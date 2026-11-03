module V1
  # The household's consoles (KVM.md), for people: what is registered, and
  # whether each answers. Registering one is a rake task
  # (hob:console:console); the bridge's key never comes out.
  #
  # GET  /v1/consoles               those visible at this clearance, disabled ones included
  # GET  /v1/consoles/:name
  # POST /v1/consoles/:name/check   → { console, reachable, bridge, device, session? } or { reachable: false, error }
  class ConsolesController < ApplicationController
    before_action :require_trusted!

    def index
      render json: Console.includes(:principal).order(:name).map(&:as_json)
    end

    def show
      render json: console.as_json
    end

    # 200 either way: unreachable is an answer.
    def check
      render json: { console: console.name }.merge(console.adapter.check)
    rescue Consoles::Error => e
      render json: { console: console.name, reachable: false, error: e.message }
    end

    private

    def console
      @console ||= Console.find_by!(name: params[:name])
    end
  end
end
