module Admin
  # Capability grants (sentinel_policies) per agent, and — the gap this
  # closes — editing what their guidance and constraints permit after the grant, through the
  # same audited path a petition's approval writes through
  # (SentinelPolicy#update_guidance!, GuidanceChange). The effect (allow |
  # deny | review | confirm) is not editable here: it has its own admin path
  # already (the sentinel petitions/requests pages), and a guidance edit must
  # never change it.
  class GrantsController < BaseController
    def index
      @agents = Principal.agents.order(:name)
      @agent = params[:agent].presence && Principal.find_by!(name: params[:agent])
      @grants = SentinelPolicy.where.not(principal_id: nil).includes(:principal).order(:capability)
      @grants = @grants.where(principal: @agent) if @agent
    end

    def show
      @grant = SentinelPolicy.find(params[:id])
      @history = @grant.guidance_changes.recent.includes(:decider, :petition)
    end

    # Guidance and constraints together: the grant's scope. Constraints come
    # in as JSON text; blank means none.
    def update
      @grant = SentinelPolicy.find(params[:id])
      scope = { guidance: params[:guidance] }
      if params.key?(:constraints)
        scope[:constraints] = params[:constraints].presence ? JSON.parse(params[:constraints]) : {}
        raise ArgumentError, "constraints must be a JSON object" unless scope[:constraints].is_a?(Hash)
      end
      @grant.update_scope!(**scope, source: "admin", decided_by: "human", decider: current_person,
                           rationale: params[:rationale].presence)
      redirect_to admin_grant_path(@grant), notice: "Updated #{@grant.principal.name}'s #{@grant.capability} rule."
    rescue ActiveRecord::RecordInvalid, JSON::ParserError, ArgumentError => e
      redirect_to admin_grant_path(@grant), alert: e.message
    end
  end
end
