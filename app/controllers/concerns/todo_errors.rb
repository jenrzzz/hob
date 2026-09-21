# What Todos raises, as HTTP, for the three controllers in front of it
# (TODOS.md). A backend that refused hob's key is hob's problem to fix, not
# the caller's, and the message says so.
module TodoErrors
  extend ActiveSupport::Concern

  included do
    rescue_from Todos::Error do |e|
      render json: { error: e.message }, status: :bad_gateway
    end

    rescue_from Todos::NotFound do |e|
      render json: { error: e.message }, status: :not_found
    end

    rescue_from Todos::Invalid do |e|
      render json: { error: e.message }, status: :unprocessable_entity
    end

    rescue_from Todos::Forbidden do |e|
      render json: { error: "the todo backend refused hob's key: #{e.message}" }, status: :forbidden
    end

    rescue_from Todos::Unavailable do |e|
      render json: { error: e.message, status: "unavailable" }, status: :service_unavailable
    end
  end
end
