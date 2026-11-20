module V1
  # A persona's life between conversations (PersonaLife), for a surface that
  # shows it (kat) and keeps the chew moving in conversation.
  #
  #   GET  /v1/personas/:key/life          diary (last 60), mood, chew, dial, last beat and whisper
  #   POST /v1/personas/:key/life/chew     { move: pick_up|chew|spit_out, subject?, from?, note?, take? }
  #   POST /v1/personas/:key/life/import   { diary: [{ entry, at, lane? }], mood?: { disposition, obsession?,
  #                                          manifestation?, at? }, chew?: { subject, from?, take?, notes?: [{ note, at }],
  #                                          picked_up_at?, moved_at? } }   once, into an empty life
  #
  # Her life is kept at its realm; a key below it reads nothing and writes
  # nothing.
  class PersonaLivesController < ApplicationController
    before_action :load_life

    rescue_from PersonaLife::Invalid do |e|
      render json: { error: e.message }, status: :unprocessable_entity
    end

    def show
      render json: @life.as_json
    end

    def chew
      at = Time.current
      @life.chew!(action: params.require(:move), subject: params[:subject], from: params[:from],
                  note: params[:note], take: params[:take], at: at)
      render json: @life.as_json
    end

    def import
      raise PersonaLife::Invalid, "#{@life.persona.key} already has a diary; import is for an empty life" if @life.last_beat_at

      Observation.transaction do
        Array(params[:diary]).each do |item|
          item = item.respond_to?(:permit!) ? item.permit!.to_h : item.to_h
          next if item["entry"].blank?

          @life.write_diary!(item["entry"], lane: item["lane"].presence, at: time(item["at"]))
        end
        if (mood = hash_param(:mood))
          @life.set_mood!(disposition: mood["disposition"], obsession: mood["obsession"],
                          manifestation: mood["manifestation"], at: time(mood["at"]))
        end
        if (chew = hash_param(:chew))
          import_chew(chew)
        end
      end
      render json: @life.as_json, status: :created
    end

    private

    def load_life
      persona = Persona.find_by!(key: params[:persona_key])
      raise PersonaLife::Invalid, "#{persona.key} has no life" if persona.life.blank?

      @life = PersonaLife.new(persona)
    end

    def time(value)
      value.present? ? Time.zone.parse(value.to_s) || Time.current : Time.current
    end

    def import_chew(chew)
      picked = time(chew["picked_up_at"])
      notes = Array(chew["notes"]).map(&:to_h)
      first = notes.first
      @life.chew!(action: "pick_up", subject: chew["subject"], from: chew["from"], note: first&.dig("note"),
                  take: chew["take"], at: picked)
      notes.drop(1).each { |n| @life.chew!(action: "chew", note: n["note"], at: time(n["at"])) }
      moved = time(chew["moved_at"].presence || chew["picked_up_at"])
      @life.chew&.update_columns(observed_at: moved)
    end
  end
end
