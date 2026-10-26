module V1
  # A person's direct situation surface (SITUATION.md). Companion-app and
  # Shortcut keys belong to the signed-in human principal, so they can write
  # only that person's row. Agents use situation.get through the sentinel.
  #
  #   GET  /v1/situation
  #   POST /v1/situation      { observations: [{ kind, slot?, value, realm?, basis?, observed_at?, ttl?, ref? }] }
  #   POST /v1/situation/end  { kind, slot? }
  class SituationController < ApplicationController
    before_action :require_trusted!

    def show
      render json: Situation.get({ "person" => Current.principal.name })
    end

    def create
      rows = Situation.observe(
        person: Current.principal,
        observations: array_param(:observations),
        by: writer
      )
      render json: { observations: rows.map { |row| observation_json(row) },
                     situation: Situation.get({ "person" => Current.principal.name }) }, status: :created
    end

    def end_observation
      rows = Situation.end_observation(
        person: Current.principal, kind: params.require(:kind), slot: params[:slot].presence, by: writer
      )
      render json: { ended: rows.map { |row| observation_json(row) },
                     situation: Situation.get({ "person" => Current.principal.name }) }
    end

    private

    def writer
      Situation::Writer.new(principal: Current.principal, surface: Current.surface, clearance: Current.clearance)
    end

    def observation_json(row)
      {
        id: row.id, person: row.person.name, kind: row.kind, slot: row.slot, value: row.value,
        realm: row.realm, basis: row.basis, source: row.source,
        observed_at: row.observed_at.utc.iso8601, expires_at: row.expires_at.utc.iso8601,
        ended_at: row.ended_at&.utc&.iso8601
      }.compact
    end
  end
end
