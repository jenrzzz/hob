module Admin
  # What hob:sentinel:pending, :decide and :petition do from a terminal: the
  # requests and petitions waiting on a person, and deciding them.
  class SentinelController < BaseController
    helper_method :existing_grant, :records_context

    def index
      @requests = SentinelRequest.pending.recent.includes(:capability, :principal, :authorization_claim)
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

    # What a person needs to see to decide a records.* request that only a
    # person may approve (RECORDS.md): the collection as proposed, the
    # schema it has beside the one asked for and how many current records
    # the new one would refuse, the record a delete would take, or how much
    # a collection delete would take with it. nil for anything else.
    def records_context(request)
      name = request.capability.name
      return nil unless request.capability.requires_person? && name.start_with?("records.")

      args = request.arguments
      return { kind: "create" } if name == "records.collection.create"

      collection = RecordCollection.live.find_by(name: args["collection"])
      return { kind: "missing", collection: args["collection"] } if collection.nil?

      case name
      when "records.collection.update"
        context = { kind: "update", collection: collection, schema_changes: args.key?("schema") && args["schema"] != collection.schema }
        if context[:schema_changes] && args["schema"].is_a?(Hash)
          context[:refused] = begin
            Records.refusals(collection, schema: args["schema"]).size
          rescue StandardError => e
            "the new schema could not be checked: #{e.message}"
          end
        end
        context
      when "records.delete"
        { kind: "delete", collection: collection, record: collection.records.live.find_by(key: args["key"].to_s) }
      when "records.collection.delete"
        live = collection.records.live
        { kind: "collection_delete", collection: collection, count: live.count, last: live.maximum(:updated_at) }
      end
    end

    def decide_request
      row = ::Sentinel.decide!(SentinelRequest.find(params[:id]), decision: params.expect(:decision),
                               decider: current_person, rationale: params[:rationale].presence,
                               fabricated: params[:fabricated] == "1")
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
