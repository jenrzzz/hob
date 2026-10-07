# A herald server as far as hob uses it (herald's API.md), answering from
# in-memory chats and messages: what Texts::Backends::Herald.transport is
# pointed at in tests. It serves /v1/chats, /v1/messages (GET and POST),
# /v1/changes, and /v1/status, honours the bearer key, and keeps every call.
# A response pushed with `respond` is served first; `pending` makes a send
# answer 202.
class FakeHerald
  Call = Struct.new(:verb, :url, :body, :headers) do
    def uri = URI(url)
    def path = uri.path
    def query = URI.decode_www_form(uri.query.to_s).to_h
    def json = body && JSON.parse(body)
  end

  KEY = "hrd_test".freeze

  attr_reader :calls, :chats, :messages, :sent
  attr_accessor :pending

  def initialize
    @calls = []
    @queued = []
    @chats = {}
    @messages = []
    @sent = []
    @seq = 1000
  end

  def to_proc
    method(:call).to_proc
  end

  # The next request gets this answer instead: [status, body hash].
  def respond(status, body)
    @queued << [ status, body ]
  end

  def chat(id, name:, handles: [ id.split(";").last ], group: false, service: "iMessage", unread: 0)
    @chats[id] = { "id" => id, "identifier" => id.split(";").last, "service" => service, "group" => group, "name" => name,
                   "display_name" => group ? name : nil, "participants" => handles.map { |h| { "handle" => h, "name" => nil } },
                   "unread" => unread }
  end

  def message(chat, text, at:, from: nil, read: true, **extra)
    @seq += 1
    sender = from && { "handle" => from, "name" => extra.delete(:name) }
    @messages << { "id" => "G-#{@seq}", "seq" => @seq, "chat_id" => chat, "from_me" => from.nil?, "sender" => sender,
                   "text" => text, "sent_at" => at, "read_at" => nil, "delivered_at" => nil, "read" => read, "service" => "iMessage",
                   "reply_to" => nil, "edited" => false, "unsent" => false, "attachments" => [], "reactions" => [] }.merge(extra.stringify_keys)
    @messages.last
  end

  def call(verb, url, body, headers)
    @calls << (call = Call.new(verb, url, body, headers))
    return encode(*@queued.shift) if @queued.any?
    return encode(401, error("unauthorized", "send a herald key")) unless headers["Authorization"] == "Bearer #{KEY}"

    encode(*route(call))
  end

  private

  def route(call)
    case [ call.verb, call.path ]
    in [ "GET", "/v1/chats" ] then [ 200, { "chats" => listed_chats(call.query) } ]
    in [ "GET", "/v1/messages" ] then list(call.query)
    in [ "GET", "/v1/changes" ] then changes(call.query)
    in [ "POST", "/v1/messages" ] then deliver(call.json)
    in [ "GET", "/v1/status" ]
      [ 200, { "herald" => "0.1.0", "macos" => "26.6.2", "database" => { "messages" => @messages.size, "chats" => @chats.size },
               "contacts" => { "people" => 3 }, "key" => { "name" => "hob", "permissions" => %w[read send], "scope" => nil } } ]
    else [ 404, error("not_found", "no such endpoint") ]
    end
  end

  def listed_chats(query)
    chats = @chats.values.map { |chat| chat.merge("last_message_at" => @messages.select { |m| m["chat_id"] == chat["id"] }.map { |m| m["sent_at"] }.max) }
    chats = chats.select { |chat| chat["name"].downcase.include?(query["q"].downcase) } if query["q"]
    chats.sort_by { |chat| chat["last_message_at"].to_s }.reverse.first(query.fetch("limit", 50).to_i)
  end

  def list(query)
    found = @messages.dup
    if query["chat"]
      return [ 404, error("not_found", "no chat #{query['chat'].inspect}", kind: "chat") ] unless @chats.key?(query["chat"])

      found.select! { |m| m["chat_id"] == query["chat"] }
    end
    found.select! { |m| m["sent_at"] >= Time.iso8601(query["after"]).utc.iso8601 } if query["after"]
    found.select! { |m| m["sent_at"] < Time.iso8601(query["before"]).utc.iso8601 } if query["before"]
    found.select! { |m| m["text"].to_s.downcase.include?(query["q"].downcase) } if query["q"]
    found.select! { |m| query["from"] == "me" ? m["from_me"] : m["sender"].to_h.values.join(" ").downcase.include?(query["from"].downcase) } if query["from"]
    found = found.sort_by { |m| -m["seq"] }
    limit = query.fetch("limit", 50).to_i
    [ 200, { "messages" => found.first(limit), "count" => [ found.size, limit ].min, "truncated" => found.size > limit,
             "searched_back_to" => nil } ]
  end

  def changes(query)
    latest = (@messages.map { |m| m["seq"] }.max || @seq).to_s
    return [ 200, { "cursor" => latest, "messages" => [], "more" => false } ] unless query["since"]

    found = @messages.select { |m| m["seq"] > query["since"].to_i }.sort_by { |m| m["seq"] }
    limit = query.fetch("limit", 100).to_i
    more = found.size > limit
    found = found.first(limit)
    cursor = more ? found.last["seq"].to_s : latest
    found.select! { |m| m["from_me"].to_s == query["from_me"] } if query["from_me"]
    [ 200, { "cursor" => cursor, "messages" => found, "more" => more } ]
  end

  def deliver(body)
    @sent << body
    chat = body["chat"] || @chats.keys.find { |id| id.end_with?(";#{body['to']}") } || "any;-;#{body['to']}"
    return [ 404, error("not_found", "no chat #{chat.inspect}", kind: "chat") ] if body["chat"] && !@chats.key?(chat)
    return [ 202, { "pending" => true, "chat_id" => chat } ] if pending

    [ 201, { "message" => message(chat, body["text"], at: "2026-10-06T17:00:00Z") } ]
  end

  def error(code, message, **extra)
    { "error" => { "code" => code, "message" => message }.merge(extra.stringify_keys) }
  end

  def encode(status, body)
    [ status.to_s, JSON.generate(body) ]
  end
end
