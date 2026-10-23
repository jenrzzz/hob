module Admin
  # What hob:sentinel:pending, :decide and :petition do from a terminal: the
  # requests and petitions waiting on a person, and deciding them.
  class SentinelController < BaseController
    helper_method :existing_grant, :records_context, :people_context, :mail_send_files_context

    # Browsers render these inline from a data URI with no new dependency;
    # heic and pdf get a metadata-only placeholder (no renderer in this stack).
    MAIL_SEND_FILES_IMAGE_TYPES = %w[image/jpeg image/png image/webp].freeze

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

    private

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
