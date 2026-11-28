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
      attrs = persona_params
      # The agent link (AgentTools) is a person's to set, at the box: a push
      # replaces the corpora and keeps it.
      attrs[:tools] = attrs[:tools].merge(persona.tools.to_h.slice("agent")) if attrs.key?(:tools)
      # Likewise where her whispers land (life.home): set with hob:persona:home.
      attrs[:life] = attrs[:life].merge(persona.life.to_h.slice("home")) if attrs.key?(:life) && attrs[:life].present?
      persona.update!(attrs)
      render json: serialize(persona)
    end

    private

    # The prompt's keys are Persona's contract (see the model); anything else is dropped.
    def persona_params
      params.permit(:key, :name, :model_role, :voice_id).to_h.tap do |h|
        if params[:prompt].present?
          h[:prompt] = params[:prompt].permit(:system_core, :instruction, greetings: [], examples: [], frames: %i[tight loose]).to_h
          # Who a particular someone is to her (Assembly::Counterpart), keyed by ref.
          h[:prompt][:relations] = params[:prompt][:relations].permit!.to_h if params[:prompt][:relations].respond_to?(:permit!)
        end
        # Memory defaults (MEMORY.md): off unless set; a turn's memory: overrides.
        h[:memory] = params[:memory].permit(:recall, :tools, :budget, :own, about: [], review: %i[every_days realm]).to_h if params[:memory].respond_to?(:permit)
        # Native corpus tools (MELUZINA.md, "Searchable collections"); {} turns them off.
        # Not `agent`: that link is set with hob:persona:agent only. `dose`: MEMORY.md, "A dose".
        h[:tools] = params[:tools].permit(:dose, corpora: [ :tool, :collection, :description, { with: [] } ]).to_h if params[:tools].respond_to?(:permit)
        # Her life between conversations (PersonaLife); {} turns it off. Not `home`.
        if params[:life].respond_to?(:permit)
          h[:life] = params[:life].permit(:instruction, :realm, :zone, :min_gap_minutes, :role, :max_iterations, :dial, :note,
                                          odds: {}, paper: %i[url odds skip], beats: {}, unworn: [],
                                          fold: %i[instruction about quiet_hours],
                                          wakes: %i[gap_minutes per_day delay_minutes jitter_minutes backoff burst burst_minutes],
                                          budget: %i[tokens_per_day], irc: [ :lines, :sheet, { stances: [] } ],
                                          company: %i[room minutes]).to_h
          h[:life][:beats] = params[:life][:beats].permit!.to_h if params[:life][:beats].respond_to?(:permit!)
          h[:life][:odds] = params[:life][:odds].permit!.to_h if params[:life][:odds].respond_to?(:permit!)
          h[:life][:lane_realms] = params[:life][:lane_realms].permit!.to_h if params[:life][:lane_realms].respond_to?(:permit!)
        end
        # Her sense of time (MELUZINA.md, "The clock"); {} turns it off.
        if params[:clock].respond_to?(:permit)
          h[:clock] = params[:clock].permit(:drift_gap_minutes, :visit_gap_hours, :calendar_window_days,
                                            zones: %i[label zone reader], calendar: %i[month day label]).to_h
        end
      end
    end

    def serialize(persona)
      {
        id: persona.id, key: persona.key, name: persona.name,
        prompt: persona.prompt, model_role: persona.model_role,
        voice_id: persona.voice_id, memory: persona.memory, clock: persona.clock, tools: persona.tools, life: persona.life, entity: persona.entity&.as_json
      }
    end
  end
end
