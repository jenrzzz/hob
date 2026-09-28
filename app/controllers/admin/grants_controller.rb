module Admin
  # Capability grants (sentinel_policies) per agent, and — the gap this
  # closes — editing what their guidance permits after the grant, through the
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

    def update
      @grant = SentinelPolicy.find(params[:id])
      @grant.update_guidance!(params[:guidance], source: "admin", decided_by: "human", decider: current_person,
                              rationale: params[:rationale].presence)
      redirect_to admin_grant_path(@grant), notice: "Updated guidance for #{@grant.principal.name}'s #{@grant.capability} rule."
    rescue ActiveRecord::RecordInvalid => e
      redirect_to admin_grant_path(@grant), alert: e.message
    end
  end
end
