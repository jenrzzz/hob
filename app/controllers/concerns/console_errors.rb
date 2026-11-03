# What Consoles raises, as HTTP, for the controllers in front of it
# (KVM.md). A bridge that refused hob's key is hob's problem to fix, not
# the caller's, and the message says so.
module ConsoleErrors
  extend ActiveSupport::Concern

  included do
    rescue_from Consoles::Error do |e|
      render json: { error: e.message }, status: :bad_gateway
    end

    rescue_from Consoles::NotFound do |e|
      render json: { error: e.message }, status: :not_found
    end

    rescue_from Consoles::Invalid do |e|
      render json: { error: e.message }, status: :unprocessable_entity
    end

    rescue_from Consoles::Forbidden do |e|
      render json: { error: "the bridge refused hob's key: #{e.message}" }, status: :forbidden
    end

    rescue_from Consoles::Unavailable do |e|
      render json: { error: e.message, status: "unavailable" }, status: :service_unavailable
    end

    rescue_from Consoles::Gone do |e|
      render json: { error: e.message }, status: :gone
    end
  end
end
