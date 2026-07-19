module V1
  class PersonasController < ApplicationController
    def index
      render json: Persona.order(:key).map { |p| serialize(p) }
    end

    def show
      render json: serialize(Persona.find_by!(key: params[:key]))
    end

    def create
      persona = Persona.create!(persona_params)
      render json: serialize(persona), status: :created
    end

    # ST character card v2/v3 -> native persona. The original card is archived
    # in card_import; conversion is lossy on purpose (no ST settings cruft).
    def import
      card = params.require(:card).permit!.to_h
      persona = Persona.from_card!(card, key: params[:key].presence)
      render json: serialize(persona), status: :created
    end

    def update
      persona = Persona.find_by!(key: params[:key])
      persona.update!(persona_params)
      render json: serialize(persona)
    end

    private

    def persona_params
      params.permit(:key, :name, :model_role, :voice_id).to_h.tap do |h|
        h[:prompt] = params[:prompt].permit!.to_h if params[:prompt].present?
      end
    end

    def serialize(persona)
      {
        id: persona.id, key: persona.key, name: persona.name,
        prompt: persona.prompt, model_role: persona.model_role,
        voice_id: persona.voice_id
      }
    end
  end
end
