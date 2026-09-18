module V1
  module Sentinel
    # Capability requests (SENTINEL.md, "Petitions and the forge").
    #
    # POST /v1/sentinel/petitions { want, capability?, arguments?, reason?, mission? }
    #   → 201 the petition: status granted|pending|building|proposed|denied,
    #     with the capability granted or proposed and the rationale.
    # GET  /v1/sentinel/petitions/:id?wait=25   poll (or long-poll) until it settles
    # GET  /v1/sentinel/petitions?status=&agent= agents see their own; people see all
    # POST /v1/sentinel/petitions/:id/decide { decision: grant|build|deny, capability?, effect?,
    #                                          constraints?, limits?, guidance?, spec?, rationale }  people only
    class PetitionsController < ApplicationController
      self.agent_actions = %i[index show create]

      before_action :require_trusted!, only: :decide

      def create
        petition = ::Sentinel.petition!(
          agent: Current.principal, want: params[:want], capability: params[:capability].presence,
          arguments: hash_param(:arguments) || {}, reason: params[:reason].presence, on_mission: params[:mission].presence
        )
        render json: serialize(petition), status: :created
      end

      def show
        row = scope.find(params[:id])
        long_poll(params[:wait]) { row.reload.settled? } if params[:wait].present? && !row.settled?
        render json: serialize(row)
      end

      def index
        rows = scope.recent.includes(:principal).limit(100)
        rows = rows.where(status: params[:status]) if params[:status].present?
        rows = rows.where(principal: Principal.find_by!(name: params[:agent])) if params[:agent].present?
        render json: rows.map { |r| serialize(r) }
      end

      def decide
        row = ::Sentinel.decide_petition!(
          Petition.find(params[:id]), decision: params.require(:decision), decider: Current.principal,
          capability: params[:capability].presence, effect: params[:effect].presence,
          constraints: hash_param(:constraints), limits: hash_param(:limits), guidance: params[:guidance].presence,
          spec: hash_param(:spec), rationale: params[:rationale].presence
        )
        render json: serialize(row)
      end

      private

      def scope
        Current.principal.agent? ? Current.principal.petitions : Petition.all
      end

      def serialize(row)
        {
          id: row.id, agent: row.principal.name, want: row.want, capability: row.capability_name,
          arguments: row.arguments.presence, reason: row.reason, realm: row.realm, status: row.status,
          action: row.action, decided_by: row.decided_by, rationale: row.rationale, decider: row.decider&.name,
          effect: row.effect, spec: row.spec.presence, policy: row.sentinel_policy_id,
          mission: row.mission_id, pull_request: row.pull_request, error: row.error, on_mission: row.on_mission_id,
          review: (row.review.presence unless Current.principal.agent?),
          created_at: row.created_at, decided_at: row.decided_at, settled_at: row.settled_at
        }.compact
      end
    end
  end
end
