module V1
  module Sentinel
    # The door for external agents.
    #
    # POST /v1/sentinel/requests { capability, arguments, reason?, mission?,
    #   user_authorization?: { quote, quoted_at, context, interpretation, action_ref } }
    #   → 201 the request: status completed|denied|pending|executing|failed,
    #     with result or rationale. Decided inline; pending means a person
    #     has to look. user_authorization (SENTINEL.md, "User-authorization
    #     claims") only ever matters to a `confirm`-effect rule, and only from
    #     a known agent with a fresh, complete quote — otherwise it is logged
    #     and ignored, same as not sending one.
    # GET  /v1/sentinel/requests/:id?wait=25   poll (or long-poll) for the outcome
    # GET  /v1/sentinel/requests?status=&agent=&days=  agents see their own; people see all.
    #   days widens the window beyond the default most-recent-100 cap, for history.
    # POST /v1/sentinel/requests/:id/decide { decision: allow|deny, rationale, fabricated? }  people only
    #   fabricated: true with deny, on a spot-checked claim, says the person
    #   never said the quoted message, and the agent freezes. Deny alone doesn't.
    class RequestsController < ApplicationController
      self.agent_actions = %i[index show create]

      before_action :require_trusted!, only: :decide

      def create
        request_row = ::Sentinel.submit!(
          agent: Current.principal, capability: params.require(:capability), arguments: hash_param(:arguments) || {},
          reason: params[:reason].presence, on_mission: params[:mission].presence,
          user_authorization: user_authorization_param
        )
        render json: serialize(request_row), status: :created
      end

      def show
        row = scope.find(params[:id])
        if params[:wait].present? && !row.settled?
          long_poll(params[:wait]) { row.reload.settled? }
        end
        render json: serialize(row)
      end

      def index
        rows = scope.recent.includes(:capability, :principal)
        rows = rows.where(status: params[:status]) if params[:status].present?
        rows = rows.where(principal: Principal.find_by!(name: params[:agent])) if params[:agent].present?
        rows = rows.since(params[:days].to_i.days.ago) if params[:days].present?
        rows = rows.limit(100) unless params[:days].present?
        render json: rows.map { |r| serialize(r) }
      end

      def decide
        row = ::Sentinel.decide!(SentinelRequest.find(params[:id]), decision: params.require(:decision),
                                 decider: Current.principal, rationale: params[:rationale].presence,
                                 fabricated: ActiveModel::Type::Boolean.new.cast(params[:fabricated]) || false)
        render json: serialize(row)
      end

      private

      # An object goes through as a hash; anything else (a bare string) goes
      # through as itself, for Claims::Intake to log as rejected.
      def user_authorization_param
        value = params[:user_authorization]
        value.respond_to?(:permit!) ? hash_param(:user_authorization) : value.presence
      end

      def scope
        Current.principal.agent? ? Current.principal.sentinel_requests : SentinelRequest.all
      end

      def serialize(row)
        {
          id: row.id, agent: row.principal.name, capability: row.capability.name, arguments: row.arguments,
          reason: row.reason, realm: row.realm, status: row.status,
          decision: row.decision, decided_by: row.decided_by, rationale: row.rationale,
          decider: row.decider&.name, review: row.review.presence, result: row.result, error: row.error,
          mission: row.mission_id, on_mission: row.on_mission_id,
          created_at: row.created_at, decided_at: row.decided_at, executed_at: row.executed_at
        }.compact
      end
    end
  end
end
