# What Browse raises, as HTTP, for the controllers in front of it
# (BROWSE.md). A browser that refused hob's key is hob's problem to fix,
# not the caller's, and the message says so.
module BrowseErrors
  extend ActiveSupport::Concern

  included do
    rescue_from Browse::Error do |e|
      render json: { error: e.message }, status: :bad_gateway
    end

    rescue_from Browse::NotFound do |e|
      render json: { error: e.message }, status: :not_found
    end

    rescue_from Browse::Invalid do |e|
      render json: { error: e.message }, status: :unprocessable_entity
    end

    rescue_from Browse::Forbidden do |e|
      render json: { error: "the browser refused hob's key: #{e.message}" }, status: :forbidden
    end

    rescue_from Browse::Unavailable do |e|
      render json: { error: e.message, status: "unavailable" }, status: :service_unavailable
    end

    rescue_from Browse::Gone do |e|
      render json: { error: e.message }, status: :gone
    end
  end
end
