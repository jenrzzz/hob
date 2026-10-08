# A JMAP mail server as far as hob uses it, answering from an in-memory
# account: what Email::Backends::Base.transport is pointed at in tests. It
# serves Fastmail's session resource and its API: Mailbox/get and /set,
# Email/query, /get, /changes, and /set, EmailSubmission/set (with
# onSuccessUpdateEmail), and Identity/get, honouring back-references and
# creation ids the way a real server does. Every call is kept; a response
# pushed with `respond` is served first.
class FakeJmap
  Call = Struct.new(:verb, :url, :body, :headers) do
    def json = body && JSON.parse(body)
    def method_calls = json ? json["methodCalls"] : []
    def methods = method_calls.map(&:first)
    def arguments(name) = method_calls.find { |call| call.first == name }&.dig(1)
  end

  class Refused < StandardError; end

  SESSION = "https://api.fastmail.com/jmap/session".freeze
  API = "https://api.fastmail.com/jmap/api/".freeze
  DOWNLOAD = "https://api.fastmail.com/jmap/download/{accountId}/{blobId}/{name}?type={type}".freeze
  TOKEN = "api-token".freeze
  ACCOUNT = "u1".freeze
  MAIL = "urn:ietf:params:jmap:mail".freeze
  SUBMISSION = "urn:ietf:params:jmap:submission".freeze
  ME = { "name" => "Jenner", "email" => "jenner@fastmail.test" }.freeze

  attr_reader :calls, :mailboxes, :emails, :submissions, :identities, :blobs
  attr_accessor :read_only, :can_send, :refuse_send, :forgotten

  def initialize
    @calls = []
    @queued = []
    @mailboxes = {}
    @emails = {}
    @blobs = {}
    @submissions = []
    @log = [] # [state, email id], one per created email
    @state = 0
    @next = 0
    @can_send = true
    @identities = [ { "id" => "i-main", "name" => "Jenner", "email" => ME["email"], "mayDelete" => false },
                    { "id" => "i-domain", "name" => "Jenner La Fave", "email" => "*@lafave.test", "mayDelete" => true } ]
    { "inbox" => "Inbox", "archive" => "Archive", "drafts" => "Drafts", "sent" => "Sent", "trash" => "Trash", "junk" => "Spam" }.each do |role, name|
      mailbox("mb-#{role}", name, role: role)
    end
  end

  def to_proc
    method(:call).to_proc
  end

  def respond(status, body = "", headers = {})
    @queued << [ status, body, headers ]
  end

  def mailbox(id, name, role: nil, parent: nil)
    @mailboxes[id] = { "id" => id, "name" => name, "parentId" => parent, "role" => role, "sortOrder" => 0, "totalEmails" => 0,
                       "unreadEmails" => 0, "myRights" => { "mayAddItems" => true } }
  end

  # A blob reachable at the download URL, as an attachment's blobId names.
  def blob(id, bytes)
    @blobs[id] = bytes.dup.force_encoding(Encoding::BINARY)
  end

  # A message on the account. `body` is its text; `html: true` makes that
  # its only (HTML) part.
  def email(id, subject:, from: "Ana Ruiz <ana@example.test>", to: [ ME ], cc: [], folders: [ "mb-inbox" ], received: "2026-10-05T16:00:00Z",
            body: "", html: false, keywords: {}, reply_to: [], message_id: "<#{id}@example.test>", references: [], attachments: [], headers: [])
    stored = {
      "id" => id, "threadId" => "t-#{id}", "mailboxIds" => Array(folders).index_with(true),
      "keywords" => keywords, "from" => addresses(from), "to" => addresses(to), "cc" => addresses(cc), "bcc" => [],
      "replyTo" => addresses(reply_to), "subject" => subject, "preview" => body.to_s.first(80), "receivedAt" => received,
      "sentAt" => received, "size" => 1000 + body.to_s.size, "hasAttachment" => attachments.any?, "messageId" => [ message_id.delete("<>") ],
      "_headers" => [ { "name" => "Received", "value" => " from mx1.example.test" }, { "name" => "Subject", "value" => " #{subject}" }, *headers ],
      "inReplyTo" => nil, "references" => references.presence, "attachments" => attachments, "_body" => body, "_html" => html
    }
    created(stored)
  end

  def call(verb, url, body, headers)
    @calls << Call.new(verb, url, body, headers)
    return @queued.shift if @queued.any?
    return [ 401, "" ] unless headers["Authorization"] == "Bearer #{TOKEN}"
    return [ 200, JSON.generate(session) ] if verb == "GET" && url == SESSION
    return [ 200, JSON.generate(api(JSON.parse(body))) ] if verb == "POST" && url == API
    if verb == "GET" && url.start_with?("https://api.fastmail.com/jmap/download/")
      blob_id = CGI.unescape(url.delete_prefix("https://api.fastmail.com/jmap/download/").split("/")[1].to_s)
      return @blobs.key?(blob_id) ? [ 200, @blobs[blob_id] ] : [ 404, "" ]
    end

    [ 404, "" ]
  end

  def api_calls
    @calls.select { |call| call.verb == "POST" }
  end

  # The arguments of the last call to `name`.
  def last(name)
    api_calls.reverse.lazy.filter_map { |call| call.arguments(name) }.first
  end

  private

  def session
    accounts = { MAIL => ACCOUNT }
    accounts[SUBMISSION] = ACCOUNT if can_send
    { "username" => ME["email"], "apiUrl" => API, "downloadUrl" => DOWNLOAD, "primaryAccounts" => accounts,
      "accounts" => { ACCOUNT => { "name" => ME["email"], "isReadOnly" => read_only == true } },
      "capabilities" => { "urn:ietf:params:jmap:core" => {}, MAIL => {} } }
  end

  def addresses(value)
    Array(value).map do |item|
      next item if item.is_a?(Hash)

      item.match(/\A(.*?)\s*<(.+)>\z/) ? { "name" => Regexp.last_match(1), "email" => Regexp.last_match(2) } : { "name" => nil, "email" => item }
    end
  end

  def created(stored)
    @emails[stored["id"]] = stored
    @state += 1
    @log << [ @state, stored["id"] ]
    stored
  end

  def touch!
    @state += 1
  end

  def api(request)
    @created = {}
    responses = []
    request["methodCalls"].each do |name, arguments, id|
      arguments = resolve(arguments, responses)
      raise Refused, "accountReadOnly" if read_only && name.end_with?("/set")

      responses.concat(perform(name, arguments, id))
    rescue Refused => e
      responses << [ "error", { "type" => e.message }, id ]
    end
    { "methodResponses" => responses, "sessionState" => "s1" }
  end

  def resolve(arguments, responses)
    arguments.each_with_object({}) do |(key, value), out|
      if key.start_with?("#")
        name, found = responses.find { |n, _, i| i == value["resultOf"] && (n == value["name"] || n == "error") }
        raise Refused, "invalidResultReference" if found.nil? || name == "error"

        out[key.delete_prefix("#")] = found[value["path"].delete_prefix("/")]
      else
        out[key] = value
      end
    end.tap do |out|
      out["ids"] = out["ids"].map { |id| id.start_with?("#") ? @created.fetch(id.delete_prefix("#"), id) : id } if out["ids"].is_a?(Array)
      out["emailId"] = @created.fetch(out["emailId"].delete_prefix("#"), out["emailId"]) if out["emailId"].is_a?(String)
    end
  end

  def perform(name, arguments, id)
    case name
    when "Mailbox/get"
      list = arguments["ids"] ? arguments["ids"].filter_map { |i| @mailboxes[i] } : @mailboxes.values
      [ [ name, { "accountId" => ACCOUNT, "list" => list, "state" => "m#{@state}" }, id ] ]
    when "Mailbox/set" then [ [ name, mailbox_set(arguments), id ] ]
    when "Email/query" then [ [ name, query(arguments), id ] ]
    when "Email/get" then [ [ name, get(arguments), id ] ]
    when "Email/changes" then [ [ name, changes(arguments), id ] ]
    when "Email/set" then [ [ name, email_set(arguments), id ] ]
    when "EmailSubmission/set" then submission_set(arguments, id)
    when "Identity/get" then [ [ name, { "accountId" => ACCOUNT, "list" => @identities }, id ] ]
    else raise Refused, "unknownMethod"
    end
  end

  def mailbox_set(arguments)
    created = {}
    not_created = {}
    (arguments["create"] || {}).each do |cid, spec|
      if @mailboxes.values.any? { |m| m["parentId"] == spec["parentId"] && m["name"].casecmp?(spec["name"]) }
        next not_created[cid] = { "type" => "alreadyExists", "description" => "a mailbox with that name is already there" }
      end

      new_id = "mb-new-#{@next += 1}"
      mailbox(new_id, spec["name"], parent: spec["parentId"])
      @created[cid] = new_id
      created[cid] = { "id" => new_id }
    end
    { "accountId" => ACCOUNT, "created" => created.presence, "notCreated" => not_created.presence }.compact
  end

  def query(arguments)
    found = @emails.values.select { |email| matches?(email, arguments["filter"]) }.sort_by { |email| email["receivedAt"] }.reverse
    { "accountId" => ACCOUNT, "ids" => found.first(arguments["limit"] || 256).map { |email| email["id"] }, "total" => found.size,
      "position" => 0, "queryState" => "q#{@state}" }
  end

  def matches?(email, filter)
    return true if filter.nil?

    if filter["operator"]
      results = filter["conditions"].map { |condition| matches?(email, condition) }
      return { "AND" => results.all?, "OR" => results.any?, "NOT" => results.none? }.fetch(filter["operator"])
    end

    who = ->(*fields) { fields.flat_map { |f| email[f] }.flat_map { |a| [ a["name"], a["email"] ] }.compact.join(" ").downcase }
    filter.all? do |key, value|
      case key
      when "inMailbox" then email["mailboxIds"][value]
      when "inMailboxOtherThan" then (email["mailboxIds"].keys - value).any?
      when "text" then [ who.call("from", "to", "cc"), email["subject"], email["_body"] ].join(" ").downcase.include?(value.downcase)
      when "from" then who.call("from").include?(value.downcase)
      when "to" then who.call("to", "cc").include?(value.downcase)
      when "subject" then email["subject"].downcase.include?(value.downcase)
      when "after" then Time.iso8601(email["receivedAt"]) >= Time.iso8601(value)
      when "before" then Time.iso8601(email["receivedAt"]) < Time.iso8601(value)
      when "hasKeyword" then email["keywords"][value]
      when "notKeyword" then !email["keywords"][value]
      when "hasAttachment" then email["hasAttachment"] == value
      else raise Refused, "unsupportedFilter"
      end
    end
  end

  def get(arguments)
    ids = arguments["ids"] || @emails.keys
    list = ids.filter_map { |id| @emails[id] }.map do |email|
      shown = email.reject { |key, _| key.start_with?("_") }
      shown["textBody"] = [ { "partId" => "1", "type" => email["_html"] ? "text/html" : "text/plain" } ]
      shown["bodyValues"] = arguments["fetchTextBodyValues"] ? { "1" => { "value" => email["_body"], "isTruncated" => false } } : {}
      shown["headers"] = email["_headers"] || [] if Array(arguments["properties"]).include?("headers")
      shown
    end
    { "accountId" => ACCOUNT, "state" => @state.to_s, "list" => list, "notFound" => ids - list.map { |e| e["id"] } }
  end

  def changes(arguments)
    since = Integer(arguments["sinceState"], exception: false)
    raise Refused, "cannotCalculateChanges" if since.nil? || (forgotten && since < forgotten)

    after = @log.select { |state, _| state > since }
    taken = after.first(arguments["maxChanges"] || 500)
    new_state = taken.size < after.size ? taken.last.first : @state
    { "accountId" => ACCOUNT, "oldState" => since.to_s, "newState" => new_state.to_s, "hasMoreChanges" => taken.size < after.size,
      "created" => taken.map(&:last), "updated" => [], "destroyed" => [] }
  end

  def email_set(arguments)
    out = { "accountId" => ACCOUNT }
    (arguments["create"] || {}).each do |cid, spec|
      new_id = "m-new-#{@next += 1}"
      body = spec.dig("bodyValues", spec.dig("textBody", 0, "partId"), "value")
      created(spec.except("bodyValues", "textBody").merge("id" => new_id, "threadId" => "t-#{new_id}", "receivedAt" => "2026-10-06T19:00:00Z",
                                                         "preview" => body.to_s.first(80), "_body" => body, "size" => body.to_s.size,
                                                         "messageId" => [ "#{new_id}@fastmail.test" ]))
      @created[cid] = new_id
      (out["created"] ||= {})[cid] = { "id" => new_id }
    end
    (arguments["update"] || {}).each do |id, patch|
      email = @emails[id]
      next (out["notUpdated"] ||= {})[id] = { "type" => "notFound" } unless email

      mailboxes = email["mailboxIds"].dup
      keywords = email["keywords"].dup
      patch.each do |path, value|
        field, key = path.split("/", 2)
        target = field == "mailboxIds" ? mailboxes : keywords
        value ? target[key] = true : target.delete(key)
      end
      next (out["notUpdated"] ||= {})[id] = { "type" => "invalidProperties", "description" => "in no mailbox" } if mailboxes.empty?

      email.merge!("mailboxIds" => mailboxes, "keywords" => keywords)
      touch!
      (out["updated"] ||= {})[id] = nil
    end
    Array(arguments["destroy"]).each { |id| @emails.delete(id) && (out["destroyed"] ||= []) << id }
    out
  end

  def submission_set(arguments, id)
    out = { "accountId" => ACCOUNT }
    updates = []
    (arguments["create"] || {}).each do |cid, spec|
      email = @emails[@created.fetch(spec["emailId"].to_s.delete_prefix("#"), spec["emailId"])]
      identity = @identities.find { |i| i["id"] == spec["identityId"] }
      if refuse_send || email.nil? || identity.nil?
        next (out["notCreated"] ||= {})[cid] = { "type" => refuse_send || "invalidProperties", "description" => "not sending that" }
      end

      @submissions << { "identity" => identity["id"], "email" => email.deep_dup }
      (out["created"] ||= {})[cid] = { "id" => "sub-#{@next += 1}" }
      patch = arguments.dig("onSuccessUpdateEmail", "##{cid}")
      updates << [ "Email/set", email_set("update" => { email["id"] => patch }), id ] if patch
    end
    [ [ "EmailSubmission/set", out, id ], *updates ]
  end
end
