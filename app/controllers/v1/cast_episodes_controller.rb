module V1
  # A cast's episodes (CASTS.md). A surface hands over an edition and hob
  # makes it in a job; the answer is the episode as it stands, to poll.
  #
  # GET  /v1/casts/:slug/episodes
  # GET  /v1/casts/:slug/episodes/:id               add ?script=1 for what the hosts say
  # POST /v1/casts/:slug/episodes { edition, briefing, title?, stories?, force? }
  #      → 202 when hob started making it, 200 when this edition already
  #        exists (made, or being made) and was left alone
  # POST /v1/casts/:slug/episodes/:id/retry { rewrite? }   a person's key
  class CastEpisodesController < ApplicationController
    before_action :require_trusted!, only: :retry

    def index
      render json: cast.episodes.newest.limit(100).map { |episode| serialize(episode) }
    end

    def show
      render json: serialize(episode, script: params[:script].present?)
    end

    def create
      episode, started = Casts.submit!(
        cast, edition: params[:edition], title: params[:title], briefing: params[:briefing],
              stories: array_param(:stories) || [], force: params[:force] == true
      )
      render json: serialize(episode), status: started ? :accepted : :ok
    rescue Casts::Invalid => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    def retry
      render json: serialize(Casts.retry!(episode, rewrite: params[:rewrite] == true)), status: :accepted
    rescue Casts::Invalid => e
      render json: { error: e.message }, status: :conflict
    end

    private

    def cast
      @cast ||= Cast.find_by!(slug: params[:cast_slug])
    end

    def episode
      @episode ||= cast.episodes.find(params[:id])
    end

    def serialize(episode, script: false)
      { id: episode.id, cast: cast.slug, edition: episode.edition, title: episode.title, summary: episode.summary,
        status: episode.status, error: episode.error, duration_ms: episode.duration_ms, audio_size: episode.audio_size,
        production: episode.production.presence, script: (episode.script.presence if script),
        published_at: episode.published_at, created_at: episode.created_at, updated_at: episode.updated_at }.compact
    end
  end
end
