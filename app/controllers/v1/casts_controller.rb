module V1
  # The shows hob produces (CASTS.md). Reading one takes any key that can
  # see its realm; making or changing one takes a person's, because a cast's
  # answer carries the address its feed is served at.
  #
  # GET   /v1/casts
  # GET   /v1/casts/:slug
  # POST  /v1/casts { slug, title, description?, realm?, config? }   → 201, or 200 for a slug that exists (an upsert)
  # PATCH /v1/casts/:slug { title?, description?, config?, rotate_token? }
  #
  # `config` is merged key by key over what the cast holds; a key set to
  # null goes back to the default (Cast::DEFAULTS).
  class CastsController < ApplicationController
    before_action :require_trusted!, only: %i[create update]

    def index
      render json: Cast.order(:slug).map { |cast| serialize(cast) }
    end

    def show
      render json: serialize(cast)
    end

    def create
      slug = params.require(:slug).to_s
      found = Cast.find_by(slug: slug)
      record = found || Cast.new(slug: slug, realm: requested_realm)
      apply(record)
      render json: serialize(record), status: found ? :ok : :created
    end

    def update
      apply(cast)
      cast.rotate_token! if params[:rotate_token] == true
      render json: serialize(cast)
    end

    private

    def cast
      @cast ||= Cast.find_by!(slug: params[:slug])
    end

    def apply(record)
      record.title = params[:title] if params[:title].present?
      record.description = params[:description] if params.key?(:description)
      if (config = hash_param(:config))
        record.config = record.config.merge(config.deep_stringify_keys).compact
      end
      record.save!
    end

    def serialize(cast)
      base = ENV["HOB_CLIENT_URL"].presence&.chomp("/") || request.base_url
      latest = cast.episodes.newest.first
      { slug: cast.slug, title: cast.title, description: cast.description, realm: cast.realm,
        config: Cast::DEFAULTS.merge(cast.config),
        feed_url: (Casts::Feed.url(cast, base) if Current.principal.trusted?),
        episodes: cast.episodes.count,
        latest: latest && { id: latest.id, edition: latest.edition, title: latest.title, status: latest.status },
        voice: Voice.available?, mixer: Casts::Mixer.available?,
        created_at: cast.created_at, updated_at: cast.updated_at }.compact
    end
  end
end
