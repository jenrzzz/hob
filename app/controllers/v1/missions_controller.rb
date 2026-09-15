module V1
  # The mission queue: work addressed to a principal that can only make
  # outbound connections, leased by polling.
  #
  # Pollers (agents and surface workers):
  #   POST /v1/missions/lease { wait?, lease? }  → 200 the mission (with lease_token), or
  #                                                200 { status: "empty" } when nothing is queued
  #   POST /v1/missions/:id/heartbeat { lease_token, lease? }
  #   POST /v1/missions/:id/complete  { lease_token, result }
  #   POST /v1/missions/:id/fail      { lease_token, error }
  #   GET  /v1/missions?status=        their own
  #   GET  /v1/missions/:id?wait=      (a creator waiting on a result may long-poll)
  # People:
  #   POST /v1/missions { assignee, title, brief?, payload?, priority?, realm? }
  #   POST /v1/missions/:id/cancel
  class MissionsController < ApplicationController
    self.agent_actions = %i[index show lease heartbeat complete fail]

    before_action :require_trusted!, only: %i[create cancel]

    def index
      rows = scope.order(created_at: :desc).limit(100)
      rows = rows.where(status: params[:status]) if params[:status].present?
      rows = rows.where(assignee: Principal.find_by!(name: params[:assignee])) if params[:assignee].present?
      render json: rows.map { |m| serialize(m) }
    end

    def show
      mission = scope.find(params[:id])
      long_poll(params[:wait]) { mission.reload.settled? } if params[:wait].present? && !mission.settled?
      render json: serialize(mission, token: mission.assignee_id == Current.principal.id)
    end

    def create
      realm = requested_realm
      assignee = Principal.find_by!(name: params.require(:assignee))
      if Realm.rank_of(assignee.max_clearance) < Realm.rank_of(realm)
        raise Gateway::Invalid, "#{assignee.name} cannot see #{realm} missions"
      end

      mission = Mission.create!(
        assignee: assignee, created_by: Current.principal, title: params.require(:title), brief: params[:brief].presence,
        payload: hash_param(:payload) || {}, priority: params[:priority].to_i, realm: realm
      )
      render json: serialize(mission), status: :created
    end

    def lease
      mission = long_poll(params[:wait]) { Mission.lease_next!(Current.principal, lease: params[:lease].presence || Mission::DEFAULT_LEASE) }
      return render json: { status: "empty" } if mission.nil?

      render json: serialize(mission, token: true)
    end

    def heartbeat
      mission = held_mission
      mission.heartbeat!(lease: params[:lease].presence || Mission::DEFAULT_LEASE)
      render json: serialize(mission, token: true)
    end

    def complete
      mission = held_mission
      result = params[:result]
      result = result.permit!.to_h if result.respond_to?(:permit!)
      mission.complete!(result)
      render json: serialize(mission)
    end

    def fail
      mission = held_mission
      mission.fail!(params[:error].presence || "failed")
      render json: serialize(mission)
    end

    def cancel
      mission = Mission.find(params[:id])
      raise Gateway::Invalid, "mission #{mission.id} is already #{mission.status}" if mission.settled?

      mission.cancel!
      render json: serialize(mission)
    end

    private

    def scope
      Current.principal.trusted? ? Mission.all : Mission.where(assignee: Current.principal).or(Mission.where(created_by: Current.principal))
    end

    # Only the assignee holding the current lease may report on a mission.
    def held_mission
      mission = Mission.where(assignee: Current.principal).find(params[:id])
      raise Gateway::Invalid, "mission #{mission.id} is #{mission.status}" unless mission.leased?
      raise Gateway::Invalid, "lease_token does not hold mission #{mission.id}" unless mission.held_by?(params[:lease_token])

      mission
    end

    def serialize(mission, token: false)
      {
        id: mission.id, assignee: mission.assignee.name, created_by: mission.created_by&.name,
        title: mission.title, brief: mission.brief, payload: mission.payload, priority: mission.priority,
        realm: mission.realm, status: mission.status, attempts: mission.attempts,
        leased_at: mission.leased_at, lease_expires_at: mission.lease_expires_at,
        result: mission.result, error: mission.error, request: mission.sentinel_request_id,
        created_at: mission.created_at, updated_at: mission.updated_at
      }.tap { |h| h[:lease_token] = mission.lease_token if token && mission.leased? }.compact
    end
  end
end
