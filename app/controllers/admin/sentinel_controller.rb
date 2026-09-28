module Admin
  # What hob:sentinel:pending, :decide and :petition do from a terminal: the
  # requests and petitions waiting on a person, and deciding them.
  class SentinelController < BaseController
    helper_method :existing_grant

    def index
      @requests = SentinelRequest.pending.recent.includes(:capability, :principal)
      @petitions = Petition.where(status: %w[pending failed]).recent.includes(:principal)
      @recent_requests = SentinelRequest.where.not(status: "pending").recent.includes(:capability, :principal, :decider).limit(15)
      @recent_petitions = Petition.where.not(status: %w[pending failed]).recent.includes(:principal, :decider).limit(15)
    end

    # The rule this petition's own agent already holds for its recommended
    # capability, if any — so the decide form can show the current guidance
    # alongside the steward's recommendation and default the textarea to it.
    def existing_grant(petition)
      name = petition.capability_name || petition.spec["name"]
      return nil if name.blank?

      SentinelPolicy.find_by(principal: petition.principal, capability: name)
    end

    def decide_request
      row = ::Sentinel.decide!(SentinelRequest.find(params[:id]), decision: params.expect(:decision),
                               decider: current_person, rationale: params[:rationale].presence)
      redirect_to admin_sentinel_path, notice: "Request #{row.id} (#{row.capability.name} for #{row.principal.name}): #{row.status}." \
                                               "#{row.error.present? ? " #{row.error}" : ''}"
    rescue Gateway::Invalid, ActionController::ParameterMissing => e
      redirect_to admin_sentinel_path, alert: e.message
    end

    def decide_petition
      row = ::Sentinel.decide_petition!(
        Petition.find(params[:id]), decision: params.expect(:decision), decider: current_person,
        capability: params[:capability].presence, effect: params[:effect].presence, guidance: params[:guidance].presence,
        rationale: params[:rationale].presence
      )
      redirect_to admin_sentinel_path, notice: "Petition #{row.id} from #{row.principal.name}: #{row.status}" \
                                               "#{row.capability_name && " #{row.capability_name}"}#{row.effect && " at #{row.effect}"}." \
                                               "#{row.error.present? ? " #{row.error}" : ''}"
    rescue Gateway::Invalid, ActionController::ParameterMissing => e
      redirect_to admin_sentinel_path, alert: e.message
    end
  end
end
