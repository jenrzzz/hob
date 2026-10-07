
module Email
  module Backends
    # A JMAP mail account (RFC 8620, RFC 8621): every mailbox on the
    # account's primary mail account, reached with a bearer token. `url` is
    # the session resource; Fastmail (the subclass) knows its own. A call
    # is one GET of the session and one POST to its apiUrl, a few method
    # calls chained by back-reference, so a search is a query and the
    # messages it found in one round trip.
    #
    # A mailbox is a folder and a label at once: a message is in one or
    # more. `move` with `to` takes it out of every mailbox the row can see
    # and puts it in that one; `add` and `remove` label it.
    #
    # `mailboxes` in the config confines a row to the mailboxes it names (by
    # id, role, name, or path) and everything under them. A message in none
    # of them does not exist for the row, and a message's other mailboxes
    # are not shown or touched. It is hob's lock alone: a token reaches the
    # whole account.
    #
    # Sending is two method calls in one request: the message is written to
    # Drafts, and an EmailSubmission sends it and, once it is accepted, moves
    # it to Sent. A submission that is refused takes its draft with it.
    class Jmap < Base
      CONFIG_KEYS = %w[url key key_env mailboxes read_only].freeze
      CORE = "urn:ietf:params:jmap:core".freeze
      MAIL = "urn:ietf:params:jmap:mail".freeze
      SUBMISSION = "urn:ietf:params:jmap:submission".freeze

      SUMMARY = %w[id threadId mailboxIds keywords size receivedAt sentAt from to cc replyTo subject preview hasAttachment].freeze
      FULL = (SUMMARY + %w[bcc messageId inReplyTo references textBody bodyValues attachments]).freeze
      MAILBOX = %w[id name parentId role sortOrder totalEmails unreadEmails myRights].freeze
      # Searched only when named: what is thrown away is not what anyone is looking for.
      UNSEARCHED_ROLES = %w[trash junk].freeze
      # Never news: what was written here, or thrown away.
      NOT_NEW_ROLES = %w[drafts sent trash junk].freeze
      MAX_CHANGES = 100
      MAX_BODY = 20_000          # characters of a body handed out
      MAX_BODY_BYTES = 256 * 1024 # of each body part asked of the server
      MAX_QUOTE = 10_000
      MAX_REFERENCES = 20
      MAX_HEADERS = 200          # header fields handed out from one message
      MAX_HEADER_VALUE = 2_000   # characters of each
      MAX_TEXT = 500
      UTC_DATE = "%Y-%m-%dT%H:%M:%SZ".freeze

      def self.config_errors(config)
        errors = unknown_errors(config, CONFIG_KEYS)
        errors += url_errors(config)
        errors += secret_errors(config, "key", "an API token", "FASTMAIL_API_TOKEN")
        if config.key?("mailboxes") && !(config["mailboxes"].is_a?(Array) && config["mailboxes"].all? { |m| m.is_a?(String) && m.present? })
          errors << "mailboxes is a list of mailbox names, paths, roles, or ids"
        end
        errors << "read_only is true or false" if config.key?("read_only") && ![ true, false ].include?(config["read_only"])
        errors
      end

      # https only: the token rides on every request.
      def self.url_errors(config)
        config["url"].to_s.match?(%r{\Ahttps://\S+\z}) ? [] : [ "needs a url (https): the server's JMAP session resource" ]
      end

      def mailboxes
        visible_mailboxes.map { |mailbox| mailbox_json(mailbox) }
      end

      def search(filter, limit)
        query = { "accountId" => account, "filter" => jmap_filter(filter), "limit" => limit, "calculateTotal" => true,
                  "sort" => [ { "property" => "receivedAt", "isAscending" => false } ] }.compact
        answers = api([ [ "Email/query", query, "q" ],
                        [ "Email/get", { "accountId" => account, "#ids" => ref("q", "Email/query", "/ids"), "properties" => SUMMARY }, "g" ] ])
        { "messages" => answers["g"]["list"].map { |email| summary(email) }, "total" => answers["q"]["total"] }
      end

      # `headers`: nil for none, :all, or the (lowercase) names wanted.
      def message(id, headers: nil)
        email = emails([ id ], headers ? FULL + [ "headers" ] : FULL, body: true).first
        raise Email::NotFound, "#{backend.name} has no message #{prefixed(id).inspect}" unless email && visible_email?(email)

        message = full(email)
        message.merge!(header_fields(email, headers)) if headers
        message
      end

      # What arrived since `state`: messages created on the account since
      # then that are not drafts, not only in drafts, sent, trash, or junk,
      # and in `mailbox` when one is named. A message moved into the inbox
      # was not created, so it is not news.
      def poll(state, mailbox)
        target = mailbox && mailbox!(mailbox)
        return { "state" => current_state, "messages" => [], "more" => false, "reset" => false } if state.nil?

        answers = api([ [ "Email/changes", { "accountId" => account, "sinceState" => state, "maxChanges" => MAX_CHANGES }, "c" ],
                        [ "Email/get", { "accountId" => account, "#ids" => ref("c", "Email/changes", "/created"), "properties" => SUMMARY }, "g" ] ])
        if answers.error("c")&.dig("type").in?(%w[cannotCalculateChanges invalidArguments])
          return { "state" => current_state, "messages" => [], "more" => false, "reset" => true }
        end

        changes = answers["c"]
        found = answers["g"]["list"].select { |email| news?(email, target) }
        { "state" => changes["newState"], "messages" => found.map { |email| summary(email) }, "more" => changes["hasMoreChanges"] == true,
          "reset" => false }
      end

      def create_mailbox(name, parent)
        writable!
        under = parent && mailbox!(parent)
        if backend.confined? && under.nil?
          raise Email::Invalid, "#{backend.name} reaches only some mailboxes: a new one goes under one of them (give a parent)"
        end

        create = { "new" => { "name" => name, "parentId" => under&.dig("id") } }
        answers = api([ [ "Mailbox/set", { "accountId" => account, "create" => create }, "s" ],
                        [ "Mailbox/get", { "accountId" => account, "ids" => [ "#new" ], "properties" => MAILBOX }, "g" ] ])
        created = answers["s"].dig("created", "new") or raise set_failure(answers["s"].dig("notCreated", "new"), "the new mailbox")
        @all_mailboxes = @by_id = @allowed_ids = nil
        mailbox_json(answers["g"]["list"].find { |m| m["id"] == created["id"] } || created.merge(create["new"]))
      end

      def move(ids, to: nil, add: [], remove: [])
        writable!
        target = to && mailbox!(to)
        adds = add.map { |ref| mailbox!(ref) }
        removes = remove.map { |ref| mailbox!(ref) }
        found = emails(ids, %w[id mailboxIds]).index_by { |email| email["id"] }

        failed = []
        update = {}
        ids.each do |id|
          email = found[id]
          next failed << { "id" => prefixed(id), "error" => "no such message" } unless email && visible_email?(email)

          patch = move_patch(email, target, adds, removes)
          next failed << { "id" => prefixed(id), "error" => "it would be in no mailbox: move it with `to` instead" } if patch.nil?

          update[id] = patch
        end
        return { "messages" => [], "failed" => failed } if update.empty?

        answers = api([ [ "Email/set", { "accountId" => account, "update" => update }, "s" ],
                        [ "Email/get", { "accountId" => account, "ids" => update.keys, "properties" => SUMMARY }, "g" ] ])
        refused = answers["s"]["notUpdated"] || {}
        refused.each { |id, error| failed << { "id" => prefixed(id), "error" => set_error_text(error) } }
        { "messages" => answers["g"]["list"].reject { |email| refused.key?(email["id"]) }.map { |email| summary(email) }, "failed" => failed }
      end

      def send_message(to:, cc:, bcc:, subject:, body:, from:)
        writable!
        sendable!
        identity, address = identity!(from)
        submit(draft(identity, address, to: to, cc: cc, bcc: bcc, subject: subject, body: body), identity)
      end

      def reply(id, body:, reply_all:, cc:, bcc:, quote:, from:)
        writable!
        sendable!
        original = emails([ id ], FULL, body: quote).first
        raise Email::NotFound, "#{backend.name} has no message #{prefixed(id).inspect}" unless original && visible_email?(original)

        identity, address = from ? identity!(from) : identity_for(original)
        to, copied = reply_recipients(original, reply_all, address)
        copied = distinct(copied + cc, except: to)
        subject = original["subject"].to_s
        subject = "Re: #{subject}".strip unless subject.match?(/\A\s*re:/i)
        text = quote ? "#{body}#{quoted(original)}" : body
        message = draft(identity, address, to: to, cc: copied, bcc: bcc, subject: subject, body: text)
        message["inReplyTo"] = Array(original["messageId"]).presence
        message["references"] = (Array(original["references"]) + Array(original["messageId"])).last(MAX_REFERENCES).presence
        sent = submit(message.compact, identity)
        answered(id)
        sent
      end

      def check
        { "reachable" => true, "account" => session["username"], "mailboxes" => visible_mailboxes.size,
          "identities" => sendable? ? identities.map { |identity| identity["email"] } : [],
          "can_send" => sendable? && !read_only_account?, "read_only" => backend.read_only? || read_only_account? }
      end

      private

      def session_url
        backend.config["url"].to_s
      end

      # --- the session and the API ---

      def session
        @session ||= begin
          status, response = deliver("GET", session_url, headers: auth_headers)
          raise status_error(status, response, "#{backend.name}'s JMAP session") unless status.between?(200, 299)

          parsed = parse(response)
          unless parsed["apiUrl"].is_a?(String) && parsed.dig("primaryAccounts", MAIL).is_a?(String)
            raise Email::Unavailable, "#{backend.name}'s JMAP session offers no mail account: is the token's Email access on?"
          end
          parsed
        end
      end

      def account
        session.dig("primaryAccounts", MAIL)
      end

      def sendable?
        session.dig("primaryAccounts", SUBMISSION).present?
      end

      def read_only_account?
        session.dig("accounts", account, "isReadOnly") == true
      end

      def writable!
        raise Email::Invalid, "#{backend.name} is read-only in hob (its row says read_only)" if backend.read_only?
        raise Email::Forbidden, "#{backend.name}'s API token is read-only: give it full Email access to file and send" if read_only_account?
      end

      def sendable!
        raise Email::Forbidden, "#{backend.name}'s API token cannot send: give it Email submission access" unless sendable?
      end

      # -> Answers: the method responses, by call id.
      def api(calls, using: [ CORE, MAIL ])
        using += [ SUBMISSION ] if calls.any? { |name, _, _| name.start_with?("EmailSubmission/", "Identity/") }
        status, response = deliver("POST", session["apiUrl"], body: JSON.generate("using" => using.uniq, "methodCalls" => calls),
                                                              headers: auth_headers.merge("Content-Type" => "application/json"))
        raise status_error(status, response, "#{backend.name}'s JMAP API") unless status.between?(200, 299)

        responses = parse(response)["methodResponses"]
        raise Email::Unavailable, "#{backend.name}'s JMAP API answered with something that is not JMAP" unless responses.is_a?(Array)

        Answers.new(responses, backend.name)
      end

      def ref(call, name, path)
        { "resultOf" => call, "name" => name, "path" => path }
      end

      def auth_headers
        key = backend.key
        raise Email::Unavailable, "#{backend.name} has no API token: #{key_hint}" if key.blank?

        { "Authorization" => "Bearer #{key}", "Accept" => "application/json" }
      end

      def key_hint
        backend.config["key_env"].present? ? "#{backend.config['key_env']} is not set in hob's environment" : "set config.key or config.key_env"
      end

      def parse(body)
        parsed = JSON.parse(body.to_s)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end

      # A request-level failure. A 400 is a request hob built wrong, so its
      # detail comes along.
      def status_error(status, response, what)
        detail = parse(response).values_at("detail", "type").compact.first
        case status
        when 401, 403 then Email::Forbidden.new("#{what} refused #{backend.name}'s API token (HTTP #{status})")
        when 404, 410 then Email::Unavailable.new("#{what} found nothing there (HTTP #{status}): has it moved?")
        when 429, 500..599 then Email::Unavailable.new("#{what} failed with HTTP #{status}")
        when 400 then Email::Error.new("#{what} refused the request: #{detail || 'HTTP 400'}")
        else Email::Unavailable.new("#{what} answered HTTP #{status}")
        end
      end

      # The method responses of one request, by call id. A method error
      # raises when its answer is asked for; `error` looks without raising.
      # The first response with an id wins: onSuccessUpdateEmail answers
      # under its submission's id too.
      class Answers
        def initialize(responses, name)
          @name = name
          @by_id = {}
          responses.each { |method, arguments, id| @by_id[id] ||= [ method, arguments.is_a?(Hash) ? arguments : {} ] }
        end

        def error(id)
          method, arguments = @by_id[id]
          method == "error" ? arguments : nil
        end

        def [](id)
          method, arguments = @by_id.fetch(id) { raise Email::Unavailable, "#{@name}'s JMAP API left a call unanswered" }
          raise method_error(arguments) if method == "error"

          arguments
        end

        private

        def method_error(arguments)
          type = arguments["type"].to_s
          text = "#{@name}'s JMAP API: #{type}#{": #{arguments['description']}" if arguments['description'].present?}"
          case type
          when "serverUnavailable", "serverFail", "serverPartialFail", "rateLimit" then Email::Unavailable.new(text)
          when "forbidden", "accountNotFound", "accountNotSupportedByMethod", "accountReadOnly" then Email::Forbidden.new(text)
          else Email::Error.new(text)
          end
        end
      end

      def set_error_text(error)
        error = error.is_a?(Hash) ? error : {}
        [ error["type"], error["description"].presence ].compact.join(": ").presence || "refused"
      end

      # A refused create (a mailbox, a draft, a submission) as one of ours.
      def set_failure(error, what)
        error = error.is_a?(Hash) ? error : {}
        text = "#{backend.name} refused #{what}: #{set_error_text(error)}"
        case error["type"]
        when "forbidden", "forbiddenFrom", "forbiddenToSend", "forbiddenMailFrom" then Email::Forbidden.new(text)
        when "rateLimit", "overQuota", "serverFail" then Email::Unavailable.new(text)
        else Email::Invalid.new(text)
        end
      end

      # --- mailboxes ---

      def all_mailboxes
        @all_mailboxes ||= api([ [ "Mailbox/get", { "accountId" => account, "ids" => nil, "properties" => MAILBOX }, "m" ] ])["m"]["list"]
      end

      def by_id
        @by_id ||= all_mailboxes.index_by { |mailbox| mailbox["id"] }
      end

      def path(mailbox)
        names = []
        seen = Set.new
        while mailbox && seen.add?(mailbox["id"])
          names.unshift(mailbox["name"].to_s)
          mailbox = by_id[mailbox["parentId"]]
        end
        names.join("/")
      end

      # The ids of the mailboxes this row may reach (the named ones and
      # everything under them), or nil when it may reach them all.
      def allowed_ids
        return nil unless backend.confined?

        @allowed_ids ||= begin
          named = backend.config["mailboxes"].filter_map { |ref| lookup(all_mailboxes, ref) }.map { |mailbox| mailbox["id"] }.to_set
          all_mailboxes.map { |mailbox| mailbox["id"] }.select { |id| ancestry(id).any? { |a| named.include?(a) } }.to_set
        end
      end

      def ancestry(id)
        ids = []
        while id && !ids.include?(id)
          ids << id
          id = by_id[id]&.dig("parentId")
        end
        ids
      end

      def allowed?(id)
        allowed_ids.nil? || allowed_ids.include?(id)
      end

      def visible_mailboxes
        all_mailboxes.select { |mailbox| allowed?(mailbox["id"]) }.sort_by { |mailbox| [ path(mailbox).downcase, mailbox["id"] ] }
      end

      def lookup(candidates, ref)
        ref = ref.to_s
        exact = candidates.find { |m| m["id"] == ref } || candidates.find { |m| m["role"].present? && m["role"] == ref.downcase } ||
                candidates.find { |m| path(m).casecmp?(ref) }
        return exact if exact

        named = candidates.select { |m| m["name"].to_s.casecmp?(ref) }
        raise Email::Invalid, "#{backend.name} has #{named.size} mailboxes named #{ref.inspect}: use the path (#{named.map { |m| path(m) }.join(', ')}) or the id" if named.size > 1

        named.first
      end

      def mailbox!(ref)
        lookup(visible_mailboxes, ref) || raise(Email::NotFound, "#{backend.name} has no mailbox #{ref.to_s.inspect}")
      end

      def role_of(id)
        by_id[id]&.dig("role")
      end

      def mailbox_json(mailbox)
        rights = mailbox["myRights"].is_a?(Hash) ? mailbox["myRights"] : {}
        { "id" => prefixed(mailbox["id"]), "backend" => backend.name, "name" => mailbox["name"], "path" => path(mailbox),
          "role" => mailbox["role"], "parent" => prefixed(mailbox["parentId"]), "total" => mailbox["totalEmails"],
          "unread" => mailbox["unreadEmails"], "may_add" => rights.fetch("mayAddItems", true) }
      end

      # --- messages ---

      def emails(ids, properties, body: false)
        arguments = { "accountId" => account, "ids" => ids, "properties" => properties }
        arguments.merge!("fetchTextBodyValues" => true, "maxBodyValueBytes" => MAX_BODY_BYTES) if body
        api([ [ "Email/get", arguments, "g" ] ])["g"]["list"]
      end

      def current_state
        api([ [ "Email/get", { "accountId" => account, "ids" => [], "properties" => [ "id" ] }, "s" ] ])["s"]["state"]
      end

      def visible_email?(email)
        email_mailbox_ids(email).any? { |id| allowed?(id) }
      end

      def email_mailbox_ids(email)
        (email["mailboxIds"].is_a?(Hash) ? email["mailboxIds"] : {}).select { |_, member| member }.keys
      end

      def news?(email, target)
        return false if email.dig("keywords", "$draft")

        ids = email_mailbox_ids(email).select { |id| allowed?(id) }
        return ids.include?(target["id"]) if target

        ids.any? { |id| !NOT_NEW_ROLES.include?(role_of(id)) }
      end

      def jmap_filter(filter)
        conditions = []
        if filter["mailbox"]
          conditions << { "inMailbox" => mailbox!(filter["mailbox"])["id"] }
        elsif allowed_ids
          searched = visible_mailboxes.reject { |m| UNSEARCHED_ROLES.include?(m["role"]) }.map { |m| m["id"] }
          conditions << { "operator" => "OR", "conditions" => searched.map { |id| { "inMailbox" => id } } }
        else
          thrown = all_mailboxes.select { |m| UNSEARCHED_ROLES.include?(m["role"]) }.map { |m| m["id"] }
          conditions << { "inMailboxOtherThan" => thrown } if thrown.any?
        end
        %w[from to subject].each { |field| conditions << { field => filter[field] } if filter[field] }
        conditions << { "text" => filter["q"] } if filter["q"]
        conditions << { "after" => filter["after"].utc.strftime(UTC_DATE) } if filter["after"]
        conditions << { "before" => filter["before"].utc.strftime(UTC_DATE) } if filter["before"]
        conditions << { (filter["unread"] ? "notKeyword" : "hasKeyword") => "$seen" } if filter.key?("unread")
        conditions << { (filter["flagged"] ? "hasKeyword" : "notKeyword") => "$flagged" } if filter.key?("flagged")
        conditions << { "hasAttachment" => filter["has_attachment"] } if filter.key?("has_attachment")
        return nil if conditions.empty?

        conditions.one? ? conditions.first : { "operator" => "AND", "conditions" => conditions }
      end

      def summary(email)
        keywords = email["keywords"].is_a?(Hash) ? email["keywords"] : {}
        shown = email_mailbox_ids(email).select { |id| allowed?(id) }.filter_map { |id| by_id[id] }
        { "id" => prefixed(email["id"]), "backend" => backend.name, "thread_id" => prefixed(email["threadId"]),
          "mailboxes" => shown.map { |m| { "id" => prefixed(m["id"]), "name" => m["name"], "role" => m["role"] } },
          "from" => addresses(email["from"]), "to" => addresses(email["to"]), "cc" => addresses(email["cc"]),
          "reply_to" => addresses(email["replyTo"]), "subject" => email["subject"]&.truncate(MAX_TEXT), "preview" => email["preview"],
          "received_at" => time(email["receivedAt"]), "sent_at" => time(email["sentAt"]), "unread" => !keywords["$seen"],
          "flagged" => keywords["$flagged"] == true, "answered" => keywords["$answered"] == true, "draft" => keywords["$draft"] == true,
          "has_attachment" => email["hasAttachment"] == true, "size" => email["size"],
          "_received" => received(email) }
      end

      def received(email)
        Time.iso8601(email["receivedAt"].to_s)
      rescue ArgumentError
        Time.at(0)
      end

      def full(email)
        text, truncated = body_text(email)
        summary(email).merge(
          "bcc" => addresses(email["bcc"]), "message_id" => Array(email["messageId"]).first,
          "in_reply_to" => Array(email["inReplyTo"]).first, "references" => Array(email["references"]),
          "body" => text, "body_truncated" => truncated,
          "attachments" => Array(email["attachments"]).map { |part| { "name" => part["name"], "type" => part["type"], "size" => part["size"] } }
        )
      end

      # The raw header fields, in the message's order (a name can repeat:
      # Received does), unfolded, and not decoded: an RFC 2047 encoded word
      # comes back as it was sent. Only the names asked for, unless :all.
      def header_fields(email, wanted)
        fields = Array(email["headers"]).select { |field| field.is_a?(Hash) && field["name"].is_a?(String) }
        fields = fields.select { |field| wanted.include?(field["name"].downcase) } unless wanted == :all
        shown = fields.first(MAX_HEADERS).map do |field|
          { "name" => field["name"], "value" => field["value"].to_s.gsub(/\r?\n[ \t]+/, " ").strip.first(MAX_HEADER_VALUE) }
        end
        truncated = fields.size > MAX_HEADERS || fields.first(MAX_HEADERS).any? { |field| field["value"].to_s.length > MAX_HEADER_VALUE }
        { "headers" => shown, "headers_truncated" => truncated }
      end

      # The message's text: its plain parts, or its HTML ones as text when
      # that is all it has.
      def body_text(email)
        parts = Array(email["textBody"])
        values = email["bodyValues"].is_a?(Hash) ? email["bodyValues"] : {}
        text = parts.filter_map do |part|
          value = values.dig(part["partId"], "value") or next
          part["type"].to_s.casecmp?("text/html") ? html_text(value) : value
        end.join("\n").strip
        truncated = parts.any? { |part| values.dig(part["partId"], "isTruncated") } || text.length > MAX_BODY
        [ text.first(MAX_BODY), truncated ]
      end

      def html_text(html)
        Web.html_text(html)
      end

      def addresses(list)
        Array(list).filter_map do |address|
          next unless address.is_a?(Hash) && address["email"].present?

          { "name" => address["name"].presence, "email" => address["email"] }
        end
      end

      def time(value)
        value.present? ? Time.iso8601(value).in_time_zone(Email.zone).iso8601 : nil
      rescue ArgumentError
        nil
      end

      # The patch that moves or labels one message, or nil when it would
      # leave the message in no mailbox. `to` leaves alone the mailboxes this
      # row cannot see.
      def move_patch(email, target, adds, removes)
        current = email_mailbox_ids(email)
        patch = {}
        current.select { |id| allowed?(id) && id != target["id"] }.each { |id| patch["mailboxIds/#{id}"] = nil } if target
        patch["mailboxIds/#{target['id']}"] = true if target
        removes.each { |mailbox| patch["mailboxIds/#{mailbox['id']}"] = nil if current.include?(mailbox["id"]) }
        adds.each { |mailbox| patch["mailboxIds/#{mailbox['id']}"] = true }
        after = (current + patch.select { |_, v| v }.keys.map { |k| k.delete_prefix("mailboxIds/") }) -
                patch.reject { |_, v| v }.keys.map { |k| k.delete_prefix("mailboxIds/") }
        after.empty? ? nil : patch
      end

      # --- sending ---

      def identities
        @identities ||= api([ [ "Identity/get", { "accountId" => session.dig("primaryAccounts", SUBMISSION), "ids" => nil }, "i" ] ])["i"]["list"]
      end

      # An identity's email may be a wildcard ("*@example.com"), which sends
      # as any address at that domain.
      def identity_matches?(identity, email)
        mine = identity["email"].to_s.downcase
        email = email.to_s.downcase
        mine.start_with?("*@") ? email.end_with?(mine.delete_prefix("*")) : mine == email
      end

      def default_identity
        concrete = identities.reject { |identity| identity["email"].to_s.start_with?("*@") }
        identity = concrete.find { |i| i["mayDelete"] == false } || concrete.first
        raise Email::Forbidden, "#{backend.name} has no identity to send as" unless identity

        [ identity, identity["email"] ]
      end

      # -> [identity, the address to send as]
      def identity!(from)
        return default_identity if from.nil?

        identity = identities.find { |i| i["email"].to_s.casecmp?(from) } || identities.find { |i| identity_matches?(i, from) }
        raise Email::Invalid, "#{from} is not one of #{backend.name}'s identities (#{identities.map { |i| i['email'] }.join(', ')})" unless identity

        [ identity, from ]
      end

      # A reply goes from the address the message was sent to, when that is
      # one of ours.
      def identity_for(original)
        (addresses(original["to"]) + addresses(original["cc"])).each do |address|
          identity = identities.find { |i| identity_matches?(i, address["email"]) }
          return [ identity, address["email"] ] if identity
        end
        default_identity
      end

      def own?(address)
        identities.any? { |identity| identity_matches?(identity, address["email"]) }
      end

      # The sender (or their Reply-To), and with reply_all everyone else on
      # it but us. A reply to a message we sent goes to whom it went to.
      def reply_recipients(original, reply_all, address)
        to = addresses(original["replyTo"]).presence || addresses(original["from"])
        to = addresses(original["to"]) if to.all? { |a| own?(a) }
        copied = reply_all ? (addresses(original["to"]) + addresses(original["cc"])).reject { |a| own?(a) || a["email"].casecmp?(address) } : []
        to = distinct(to)
        raise Email::Invalid, "#{prefixed(original['id'])} has no one to reply to" if to.empty?

        [ to, distinct(copied, except: to) ]
      end

      def distinct(list, except: [])
        taken = except.map { |a| a["email"].downcase }.to_set
        list.select { |a| taken.add?(a["email"].downcase) }
      end

      def quoted(original)
        text, = body_text(original)
        return "" if text.blank?

        who = addresses(original["from"]).first
        who = who && (who["name"] || who["email"])
        on = time(original["sentAt"] || original["receivedAt"])
        on = on && Time.iso8601(on).strftime("%a, %b %-d, %Y at %-l:%M %p")
        lines = text.first(MAX_QUOTE).lines.map { |line| line.chomp.empty? ? ">" : "> #{line.chomp}" }
        "\n\nOn #{[ on, who ].compact.join(', ')} wrote:\n#{lines.join("\n")}\n"
      end

      def drafts_id
        all_mailboxes.find { |m| m["role"] == "drafts" }&.dig("id") || raise(Email::Unavailable, "#{backend.name} has no Drafts mailbox to write in")
      end

      def sent_id
        all_mailboxes.find { |m| m["role"] == "sent" }&.dig("id")
      end

      def draft(identity, address, to:, cc:, bcc:, subject:, body:)
        { "mailboxIds" => { drafts_id => true }, "keywords" => { "$draft" => true, "$seen" => true },
          "from" => [ { "name" => identity["name"].presence, "email" => address }.compact ],
          "to" => to.presence, "cc" => cc.presence, "bcc" => bcc.presence, "subject" => subject,
          "bodyValues" => { "body" => { "value" => body } }, "textBody" => [ { "partId" => "body", "type" => "text/plain" } ] }.compact
      end

      # Write the draft and send it in one request. -> the sent message.
      def submit(message, identity)
        sent = { "keywords/$draft" => nil }
        sent.merge!("mailboxIds/#{drafts_id}" => nil, "mailboxIds/#{sent_id}" => true) if sent_id
        submission = { "identityId" => identity["id"], "emailId" => "#draft" }
        answers = api([
          [ "Email/set", { "accountId" => account, "create" => { "draft" => message } }, "d" ],
          [ "EmailSubmission/set", { "accountId" => session.dig("primaryAccounts", SUBMISSION), "create" => { "send" => submission },
                                     "onSuccessUpdateEmail" => { "#send" => sent } }, "s" ],
          [ "Email/get", { "accountId" => account, "ids" => [ "#draft" ], "properties" => SUMMARY }, "g" ]
        ])
        email_id = answers["d"].dig("created", "draft", "id") or raise set_failure(answers["d"].dig("notCreated", "draft"), "the message")
        unless answers["s"].dig("created", "send")
          discard(email_id)
          raise set_failure(answers["s"].dig("notCreated", "send"), "to send the message")
        end
        found = answers.error("g") ? nil : answers["g"]["list"].first
        found ? summary(found) : { "id" => prefixed(email_id), "backend" => backend.name }
      end

      # hob's own draft, left behind by a refused submission.
      def discard(email_id)
        api([ [ "Email/set", { "accountId" => account, "destroy" => [ email_id ] }, "x" ] ])
      rescue Email::Error
        nil
      end

      # The message was replied to. Its sending already stands, so a failure
      # here is not the reply's.
      def answered(id)
        api([ [ "Email/set", { "accountId" => account, "update" => { id => { "keywords/$answered" => true } } }, "a" ] ])
      rescue Email::Error
        nil
      end
    end
  end
end
