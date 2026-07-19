module V1
  class PresetsController < ApplicationController
    def index
      render json: Preset.order(:key).map { |p| serialize(p) }
    end

    def show
      render json: serialize(Preset.find_by!(key: params[:key]))
    end

    def create
      preset = Preset.create!(preset_params)
      render json: serialize(preset), status: :created
    end

    def update
      preset = Preset.find_by!(key: params[:key])
      preset.update!(preset_params)
      render json: serialize(preset)
    end

    def destroy
      Preset.find_by!(key: params[:key]).destroy!
      head :no_content
    end

    private

    def preset_params
      params.permit(:key, :name).to_h.tap do |h|
        h[:stages] = params[:stages].map { |s| s.permit(:name, :enabled, :budget).to_h } if params[:stages].present?
        h[:params] = params[:params].permit!.to_h if params[:params].present?
      end
    end

    def serialize(preset)
      { key: preset.key, name: preset.name, stages: preset.stage_config, params: preset.params }
    end
  end
end
