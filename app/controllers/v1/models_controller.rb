module V1
  class ModelsController < ApplicationController
    def index
      render json: ModelRole.order(:role).map { |mr|
        resolved = begin
          r = mr.resolve
          { provider: r.provider.slug, model: r.model, price: ModelPrice.for_model(r.model)&.as_json&.slice(:model, :input, :output) }
        rescue Gateway::NoProviderError
          nil
        end
        { role: mr.role, chain: mr.chain, resolved: resolved }
      }
    end
  end
end
