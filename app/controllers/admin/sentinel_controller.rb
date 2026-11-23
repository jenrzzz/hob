module Admin
  # What hob:sentinel:pending, :decide and :petition do from a terminal: the
  # requests and petitions waiting on a person, and deciding them.
  class SentinelController < BaseController
    helper_method :existing_grant, :records_context, :people_context, :mail_send_files_context, :ward_threat_context,
                  :history_filters

    # Browsers render these inline from a data URI with no new dependency;
    # heic and pdf get a metadata-only placeholder (no renderer in this stack).
    MAIL_SEND_FILES_IMAGE_TYPES = %w[image/jpeg image/png image/webp].freeze

    HISTORY_PAGE = 50
    HISTORY_KINDS = %w[requests petitions].freeze

    # What waits on a person, then the whole history below it, newest first,
    # a page at a time: `before` is the last row's cursor, and `rows=1`
    # answers with just the next page's rows for the page to append as it
    # scrolls.
    def index
      load_history
      return render(partial: "history_chunk", layout: false) if params[:rows].present?

      @requests = SentinelRequest.pending.recent.includes(:capability, :principal, :authorization_claim)
      @petitions = Petition.where(status: %w[pending failed]).recent.includes(:principal)
    end

    # One request, as the iOS app's RequestView shows it: what was asked,
    # who decided and why, what came of it; and here also the grant it was
    # asked under, what deciding it cost, and the agent's other asks of the
    # same capability.
    def show_request
      @request_row = SentinelRequest.includes(:capability, :principal, :decider, :authorization_claim).find(params[:id])
      @grant = SentinelPolicy.find_by(principal: @request_row.principal, capability: @request_row.capability.name)
      @usage = usage_for(@request_row.ref)
      @related = SentinelRequest.where(principal: @request_row.principal, capability: @request_row.capability)
                                .where.not(id: @request_row.id).recent.includes(:decider).limit(10)
    end

    def show_petition
      @petition = Petition.includes(:principal, :decider).find(params[:id])
      @grant = @petition.sentinel_policy_id && SentinelPolicy.find_by(id: @petition.sentinel_policy_id)
      @usage = usage_for(@petition.ref)
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

    # What a person needs to see to decide a people.* request only a person
    # may approve (PEOPLE.md): both records a merge would make one, whose a
    # handle already is, the loop a dismissal would close. nil for anything else.
    def people_context(request)
      name = request.capability.name
      return nil unless request.capability.requires_person? && name.start_with?("people.")

      args = request.arguments
      find = lambda do |value|
        People.person!(value)
      rescue People::Error
        nil
      end
      case name
      when "people.merge" then { into: find.call(args["into"]), from: find.call(args["from"]) }
      when "people.handle.add" then { person: find.call(args["person"]), owner: find.call(args["handle"]) }
      when "people.loop.dismiss" then { loop: PeopleLoop.outstanding.find_by(id: args["loop"].to_s.delete_prefix("loop:")) }
      end
    end

    # What a person needs to see to decide a ward.threat.* request held for
    # them (THREATS.md): the threat it acts on, as the ward holds it. nil for
    # anything else.
    def ward_threat_context(request)
      name = request.capability.name
      return nil unless name.start_with?("ward.threat.") && name != "ward.threat.report"

      { threat: WardThreat.find_by(id: request.arguments["threat"].to_s) }
    end

    # What a person needs to see to decide a pending hob.mail.send_files
    # request without the generic fallback ever printing raw base64: the
    # message as it would send, and for each attachment its own facts and,
    # for bytes the stack can preview inline, a thumbnail built from them.
    # nil for anything else.
    def mail_send_files_context(request)
      return nil unless request.capability.name == "hob.mail.send_files"

      args = request.arguments
      { account: args["account"], to: Array(args["to"]), cc: Array(args["cc"]),
        subject: args["subject"], body: args["body"],
        attachments: Array(args["attachments"]).map { |entry| mail_send_files_attachment(entry) } }
    end

    def decide_request
      row = ::Sentinel.decide!(SentinelRequest.find(params[:id]), decision: params.expect(:decision),
                               decider: current_person, rationale: params[:rationale].presence,
                               fabricated: params[:fabricated] == "1")
      redirect_back_or_to admin_sentinel_path, notice: "Request #{row.id} (#{row.capability.name} for #{row.principal.name}): #{row.status}." \
                                               "#{row.error.present? ? " #{row.error}" : ''}"
    rescue Gateway::Invalid, ActionController::ParameterMissing => e
      redirect_back_or_to admin_sentinel_path, alert: e.message
    end

    def decide_petition
      row = ::Sentinel.decide_petition!(
        Petition.find(params[:id]), decision: params.expect(:decision), decider: current_person,
        capability: params[:capability].presence, effect: params[:effect].presence, guidance: params[:guidance].presence,
        constraints: constraints_param, rationale: params[:rationale].presence
      )
      redirect_back_or_to admin_sentinel_path, notice: "Petition #{row.id} from #{row.principal.name}: #{row.status}" \
                                               "#{row.capability_name && " #{row.capability_name}"}#{row.effect && " at #{row.effect}"}." \
                                               "#{row.error.present? ? " #{row.error}" : ''}"
    rescue Gateway::Invalid, ActionController::ParameterMissing => e
      redirect_back_or_to admin_sentinel_path, alert: e.message
    end

    # The history's filters as given, for links that keep them.
    def history_filters
      params.permit(:agent, :capability, :status, :kind).to_h.compact_blank.symbolize_keys
    end

    private

    # Requests and petitions merged into one list by (created_at, id),
    # filtered, and cut after HISTORY_PAGE. The cursor is that pair, so a
    # page never repeats or skips a row however many arrive meanwhile.
    def load_history
      f = history_filters
      agent = f[:agent] && Principal.find_by(name: f[:agent])
      before = parse_cursor(params[:before])
      scopes = []
      unless f[:kind] == "petitions"
        scope = SentinelRequest.includes(:capability, :principal, :decider)
        scope = scope.where(capability: Capability.where(name: f[:capability])) if f[:capability]
        scopes << scope
      end
      unless f[:kind] == "requests"
        scope = Petition.includes(:principal, :decider)
        scope = scope.where(capability_name: f[:capability]) if f[:capability]
        scopes << scope
      end
      rows = scopes.flat_map do |scope|
        scope = scope.where(principal: agent) if f[:agent]
        scope = scope.where(status: f[:status]) if f[:status]
        scope = scope.where("(#{scope.table_name}.created_at, #{scope.table_name}.id) < (?, ?)", *before) if before
        scope.order(created_at: :desc, id: :desc).limit(HISTORY_PAGE + 1).to_a
      end
      rows.sort_by! { |row| [ row.created_at, row.id ] }.reverse!
      @history = rows.first(HISTORY_PAGE)
      last = @history.last
      @history_next = rows.size > HISTORY_PAGE && last && "#{last.created_at.utc.iso8601(6)}~#{last.id}"
      @history_agents = Principal.agents.order(:name).pluck(:name)
      @history_capabilities = Capability.order(:name).pluck(:name)
      @history_statuses = (SentinelRequest::STATUSES + Petition::STATUSES).uniq.sort
    end

    def parse_cursor(value)
      time, id = value.to_s.split("~", 2)
      return nil if time.blank? || id.blank?

      [ Time.iso8601(time), id ]
    rescue ArgumentError
      nil
    end

    # What hob spent deciding it: the reviewer's, steward's or claim
    # check's model calls, which carry the row's ref.
    def usage_for(ref)
      events = UsageEvent.where(ref: ref)
      { calls: events.count, cost: events.sum(:cost).to_f, ref: ref }
    end

    # The petition form's constraints box: the whole object as JSON, or
    # blank to leave a held grant's constraints as they are.
    def constraints_param
      return nil if params[:constraints].blank?

      value = JSON.parse(params[:constraints])
      raise Gateway::Invalid, "constraints must be a JSON object of argument => rule" unless value.is_a?(Hash)

      value
    rescue JSON::ParserError => e
      raise Gateway::Invalid, "constraints is not JSON: #{e.message}"
    end

    # A reference (message_id, attachment_id: no bytes) or an upload
    # (filename, mime_type, content_base64), exactly as Email.file_entry!
    # tells them apart — but tolerant of whatever a still-pending request
    # holds, since nothing has validated it yet.
    def mail_send_files_attachment(entry)
      entry = entry.is_a?(Hash) ? entry : {}
      return { kind: :ref, message_id: entry["message_id"], attachment_id: entry["attachment_id"] } if entry.key?("message_id") || entry.key?("attachment_id")

      mail_send_files_upload(entry)
    end

    def mail_send_files_upload(entry)
      bytes = mail_send_files_decode(entry["content_base64"])
      { kind: :upload, filename: entry["filename"], mime_type: entry["mime_type"], size: bytes&.bytesize,
        sha256: bytes && Digest::SHA256.hexdigest(bytes), preview: mail_send_files_preview(entry["mime_type"], bytes) }
    end

    def mail_send_files_decode(value)
      return nil unless value.is_a?(String) && value.present?

      Base64.strict_decode64(value)
    rescue ArgumentError
      nil
    end

    # -> { kind: :image, data_uri } | { kind: :pdf } | { kind: :text, excerpt } |
    #    { kind: :unsupported, note } | { kind: :undecodable }. Never the bytes
    #    themselves outside the data URI a real inline image needs.
    def mail_send_files_preview(mime_type, bytes)
      return { kind: :undecodable } if bytes.nil?

      case mime_type
      when *MAIL_SEND_FILES_IMAGE_TYPES
        { kind: :image, data_uri: "data:#{mime_type};base64,#{Base64.strict_encode64(bytes)}" }
      when "image/heic"
        { kind: :unsupported, note: "heic has no inline preview in this stack; showing file facts only" }
      when "application/pdf"
        { kind: :pdf }
      when "text/plain"
        { kind: :text, excerpt: mail_send_files_excerpt(bytes) }
      else
        { kind: :unsupported, note: "no inline preview for this file type; showing file facts only" }
      end
    end

    def mail_send_files_excerpt(bytes, limit = 500)
      text = bytes.dup.force_encoding(Encoding::UTF_8).scrub("�")
      text.length > limit ? "#{text[0, limit]}…" : text
    end
  end
end
