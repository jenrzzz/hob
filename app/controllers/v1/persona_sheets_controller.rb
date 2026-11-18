module V1
  # A persona's sheet (MEMORY.md, "The sheet"). Anyone with a model-facing
  # key may read it and propose; applying, rejecting, and rolling back are a
  # person's. The constitution (prompt.system_core) is not here: it changes
  # only through PATCH /v1/personas/:key.
  #
  #   GET  /v1/personas/:key/sheet?version=
  #   GET  /v1/personas/:key/sheet/revisions?status=
  #   POST /v1/personas/:key/sheet/revisions             { ops, citations, rationale? }
  #   POST /v1/personas/:key/sheet/revisions/:id/apply | /reject
  #   POST /v1/personas/:key/sheet/rollback              { version, rationale? }
  #   POST /v1/personas/:key/sheet/accrete               { since?, observations?, role?, limit? }
  #   POST /v1/personas/:key/sheet/review                { role? }
  class PersonaSheetsController < ApplicationController
    before_action :require_trusted!, only: %i[apply reject rollback]

    def show
      render json: sheet.as_json(version: params[:version].presence&.to_i)
    end

    def revisions
      scope = persona.sheet_revisions.order(version: :desc)
      scope = scope.where(status: params[:status]) if params[:status].present?
      render json: { revisions: scope.limit(200).map(&:as_json) }
    end

    def propose
      revision = sheet.propose!(ops: array_param(:ops), citations: Array(params[:citations]),
                                rationale: params[:rationale].presence)
      render json: revision.as_json, status: :created
    end

    def apply
      render json: { revision: sheet.apply!(revision).as_json, sheet: sheet.as_json }
    end

    def reject
      render json: { revision: sheet.reject!(revision).as_json }
    end

    def rollback
      done = sheet.rollback!(to: params.require(:version), rationale: params[:rationale].presence)
      render json: { revision: done.as_json, sheet: sheet.as_json }
    end

    def accrete
      outcome = PersonaSheet::Accretion.new(
        persona, since: params[:since].presence, observation_ids: Array(params[:observations]).presence,
                 role: params[:role].presence, limit: params[:limit].presence
      ).call
      render json: { proposed: outcome.proposed.map(&:as_json), dropped: outcome.dropped,
                     window: outcome.window, completion: outcome.completion }, status: :created
    end

    # The long look: a second, larger model reads the whole file (MEMORY.md, "Review").
    def review
      outcome = PersonaSheet::Review.new(persona, role: params[:role].presence).call
      render json: { proposed: outcome.proposed.map(&:as_json), dropped: outcome.dropped,
                     insights: outcome.insights.map(&:as_json), ruts: outcome.ruts.map(&:as_json),
                     window: outcome.window, completion: outcome.completion }, status: :created
    end

    private

    def persona
      @persona ||= Persona.find_by!(key: params[:persona_key] || params[:key])
    end

    def sheet
      @sheet ||= PersonaSheet.new(persona)
    end

    def revision
      persona.sheet_revisions.find(params[:id])
    end
  end
end
