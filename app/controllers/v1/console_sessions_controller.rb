module V1
  # Console sessions, for people (KVM.md): a person's key reaches any
  # visible session, to look or to close it. Agents open and drive sessions
  # through the console.* sentinel capabilities, and get 403 here.
  #
  # GET    /v1/console_sessions                   every open session visible at this clearance
  # GET    /v1/console_sessions/:id               the row; ?screen=1&scale= adds a fresh frame (base64 PNG)
  # DELETE /v1/console_sessions/:id               → { session }
  class ConsoleSessionsController < ApplicationController
    include ConsoleErrors

    before_action :require_trusted!

    def index
      render json: { sessions: Consoles.sessions.map(&:as_json) }
    end

    def show
      if params[:screen].to_s == "1"
        render json: Consoles.screen(params[:id], scale: params[:scale]).merge("notice" => Consoles::NOTICE)
      else
        render json: { session: Consoles.locate(params[:id], open: false).as_json }
      end
    end

    def destroy
      render json: { session: Consoles.close(params[:id]) }
    end
  end
end
