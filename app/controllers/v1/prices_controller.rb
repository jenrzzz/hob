module V1
  # Model prices, USD per million tokens (ModelPrice). Anyone with a
  # non-agent key may read; people set them.
  #
  # GET    /v1/prices                → { prices: [...], unpriced: [model ids the ledger has seen without a price] }
  # GET    /v1/prices/:model         → the row that prices this id (prefix match), 404 if none
  # PUT    /v1/prices/:model         { input, output, cache_read?, cache_write?, note?, effective_from?, reprice? }
  #                                  → the row, plus `repriced`: ledger rows recomputed
  # DELETE /v1/prices/:model
  class PricesController < ApplicationController
    before_action :require_trusted!, only: %i[update destroy]

    def index
      render json: { prices: ModelPrice.order(:model).map(&:as_json), unpriced: ModelPrice.unpriced_models }
    end

    def show
      row = ModelPrice.for_model(params[:model])
      raise ActiveRecord::RecordNotFound if row.nil?

      render json: row.as_json.merge(matched: params[:model])
    end

    def update
      row = ModelPrice.set!(
        model: params[:model], input: params.require(:input), output: params.require(:output),
        cache_read: params[:cache_read].presence, cache_write: params[:cache_write].presence,
        note: params[:note].presence, effective_from: params[:effective_from].presence,
        reprice: params[:reprice].nil? ? true : ActiveModel::Type::Boolean.new.cast(params[:reprice])
      )
      render json: row.as_json.merge(repriced: row.repriced), status: row.previously_new_record? ? :created : :ok
    end

    def destroy
      ModelPrice.find(params[:model]).destroy!
      head :no_content
    end
  end
end
