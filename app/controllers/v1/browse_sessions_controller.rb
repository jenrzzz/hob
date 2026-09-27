module V1
  # Browsing sessions for surfaces and people (BROWSE.md); agents reach the
  # same through the browse.* sentinel capabilities.
  #
  # GET    /v1/browse_sessions                       open sessions: the caller's, or every visible one for a person
  # POST   /v1/browse_sessions { goal, url, browser?, domains?, ttl?, screenshot?, max_chars? }   → 201 state
  # GET    /v1/browse_sessions/:id?screenshot=1&max_chars=   the page now
  # POST   /v1/browse_sessions/:id/actions { action, ...its arguments, screenshot?, max_chars? } → state
  # DELETE /v1/browse_sessions/:id                   → { session }
  class BrowseSessionsController < ApplicationController
    include BrowseErrors

    def index
      render json: { sessions: Browse.sessions.map(&:as_json) }
    end

    def create
      state = Browse.open(
        goal: params[:goal], url: params[:url], browser: params[:browser], domains: params[:domains],
        ttl: params[:ttl], screenshot: params[:screenshot] == true, max_chars: params[:max_chars]
      )
      render json: state, status: :created
    end

    def show
      render json: Browse.state(params[:id], screenshot: params[:screenshot].to_s == "1", max_chars: params[:max_chars])
    end

    # The step's own `action` would be shadowed by the routing one in
    # `params`, so the body is read as posted (minus the wrapper Rails adds).
    def act
      render json: Browse.act(params[:id], request.request_parameters.to_h.except("browse_session"))
    end

    def destroy
      render json: { session: Browse.close(params[:id]) }
    end
  end
end
