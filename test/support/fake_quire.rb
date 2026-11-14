# A quire server as far as hob uses it (quire's API.md), answering from
# in-memory folders and notes: what Notes::Backends::Quire.transport is
# pointed at in tests. It serves /v1/folders, /v1/notes (GET, POST),
# /v1/notes/:id (GET, PATCH), and /v1/status, honours the bearer key, and
# keeps every call. A response pushed with `respond` is served first.
class FakeQuire
  Call = Struct.new(:verb, :url, :body, :headers) do
    def uri = URI(url)
    def path = uri.path
    def query = URI.decode_www_form(uri.query.to_s).to_h
    # Repeated params (tag=a&tag=b) as lists.
    def params = URI.decode_www_form(uri.query.to_s).group_by(&:first).transform_values { |pairs| pairs.map(&:last) }
    def json = body && JSON.parse(body)
  end

  KEY = "qre_test".freeze
  STORE = "x-coredata://5C1F0000-AAAA-BBBB-CCCC-000000000001".freeze
  ACCOUNT = { "id" => "#{STORE}/ICAccount/p3", "name" => "iCloud" }.freeze

  attr_reader :calls, :folders, :notes, :writes

  def initialize
    @calls = []
    @queued = []
    @folders = {}
    @notes = {}
    @writes = []
    @seq = 100
  end

  def to_proc
    method(:call).to_proc
  end

  # The next request gets this answer instead: [status, body hash].
  def respond(status, body)
    @queued << [ status, body ]
  end

  def folder(name, parent: nil)
    id = "#{STORE}/ICFolder/p#{@seq += 1}"
    parent_row = parent && @folders.fetch(parent)
    @folders[id] = { "id" => id, "name" => name, "path" => [ parent_row&.dig("path"), name ].compact.join(" : "),
                     "account" => ACCOUNT, "parent" => parent_row && parent_row.slice("id", "name"), "shared" => false }
    id
  end

  def note(folder, title, text: "", modified:, created: modified, locked: false, shared: false)
    id = "#{STORE}/ICNote/p#{@seq += 1}"
    @notes[id] = { "id" => id, "folder_id" => folder, "title" => title, "text" => "#{title}\n#{text}", "created" => created,
                   "modified" => modified, "locked" => locked, "shared" => shared }
    id
  end

  def call(verb, url, body, headers)
    @calls << (call = Call.new(verb, url, body, headers))
    return encode(*@queued.shift) if @queued.any?
    return encode(401, error("unauthorized", "send a quire key")) unless headers["Authorization"] == "Bearer #{KEY}"

    encode(*route(call))
  end

  private

  def route(call)
    if call.path.start_with?("/v1/notes/")
      raw = call.path.delete_prefix("/v1/notes/")
      return [ 404, error("not_found", "no such endpoint: a note id is one percent-encoded path segment") ] if raw.include?("/")

      id = URI.decode_uri_component(raw)

      note = @notes[id] or return [ 404, error("not_found", "no note with id #{id.inspect}", kind: "note") ]
      return [ 200, shown(note, full: true) ] if call.verb == "GET"
      return update(note, call.json) if call.verb == "PATCH"
    end
    case [ call.verb, call.path ]
    in [ "GET", "/v1/folders" ] then [ 200, { "folders" => listed_folders(call.query) } ]
    in [ "GET", "/v1/notes" ] then list(call.params)
    in [ "POST", "/v1/notes" ] then create(call.json)
    in [ "GET", "/v1/status" ]
      [ 200, { "quire" => "0.1.0", "notes_app" => { "version" => "4.13" }, "counts" => { "notes" => @notes.size, "folders" => @folders.size, "accounts" => 1 },
               "key" => { "name" => "hob", "permissions" => %w[read write], "scope" => nil }, "now" => "2026-11-14T17:00:00.000Z" } ]
    else [ 404, error("not_found", "no such endpoint") ]
    end
  end

  def listed_folders(query)
    found = @folders.values.map do |folder|
      folder.merge("note_count" => @notes.values.count { |n| n["folder_id"] == folder["id"] },
                   "folder_count" => @folders.values.count { |f| f.dig("parent", "id") == folder["id"] })
    end
    found = found.select { |folder| folder["path"].downcase.include?(query["q"].downcase) } if query["q"]
    found
  end

  def within?(note, folder)
    id = note["folder_id"]
    while id
      return true if id == folder

      id = @folders.dig(id, "parent", "id")
    end
    false
  end

  def list(params)
    one = params.transform_values(&:first)
    found = @notes.values
    if one["folder"]
      return [ 404, error("not_found", "no folder #{one['folder'].inspect}", kind: "folder") ] unless @folders.key?(one["folder"])

      found = found.select { |n| within?(n, one["folder"]) }
    end
    found = found.select { |n| one["q"].downcase.split.all? { |w| n["text"].downcase.include?(w) } } if one["q"]
    found = found.select { |n| params["tag"].all? { |t| tags(n).include?(t) } } if params["tag"]
    found = found.select { |n| n["modified"] >= Time.iso8601(one["modified_after"]).utc.iso8601 } if one["modified_after"]
    found = found.select { |n| n["modified"] < Time.iso8601(one["modified_before"]).utc.iso8601 } if one["modified_before"]
    found = found.sort_by { |n| n["modified"] }.reverse
    limit = one.fetch("limit", 50).to_i
    text = one["q"] || params["tag"] || one["include"] == "snippet"
    [ 200, { "notes" => found.first(limit).map { |n| shown(n, text: text) }, "total" => found.size, "limit" => limit, "offset" => 0 } ]
  end

  def create(body)
    @writes << [ "POST", nil, body ]
    folder = body["folder"] || @folders.keys.first
    return [ 404, error("not_found", "no folder #{folder.inspect}", kind: "folder") ] unless @folders.key?(folder)

    title = body["title"] || body["text"].to_s.lines.first.to_s.chomp
    id = note(folder, title, text: body["text"].to_s.lines.drop(body["title"] ? 0 : 1).join, modified: "2026-11-14T17:00:00Z")
    [ 201, shown(@notes[id], full: true) ]
  end

  def update(note, body)
    @writes << [ "PATCH", note["id"], body ]
    return [ 422, error("invalid", "the note is locked") ] if note["locked"]

    note["title"] = body["title"] if body["title"]
    note["text"] = "#{note['title']}\n#{body['text']}" if body["text"]
    note["text"] += "\n#{body['append']}" if body["append"]
    if body["folder"]
      return [ 404, error("not_found", "no folder #{body['folder'].inspect}", kind: "folder") ] unless @folders.key?(body["folder"])

      note["folder_id"] = body["folder"]
    end
    note["modified"] = "2026-11-14T17:05:00Z"
    [ 200, shown(note, full: true) ]
  end

  def tags(note)
    note["text"].scan(/(?:^|\s)#([\p{L}\p{N}_-]+)/).flatten
  end

  def shown(note, full: false, text: false)
    folder = @folders.fetch(note["folder_id"])
    out = { "id" => note["id"], "title" => note["title"], "folder" => folder.slice("id", "name", "path"), "account" => ACCOUNT,
            "created" => note["created"], "modified" => note["modified"], "locked" => note["locked"], "shared" => note["shared"] }
    if full || text
      out["snippet"] = note["locked"] ? nil : note["text"].lines.drop(1).join.strip[0, 200]
      out["tags"] = note["locked"] ? nil : tags(note)
    end
    if full
      out["text"] = note["locked"] ? nil : note["text"]
      out["html"] = note["locked"] ? nil : note["text"].lines.map { |l| "<div>#{CGI.escapeHTML(l.chomp)}</div>" }.join
      out["attachments"] = [ { "id" => "#{STORE}/ICAttachment/p9", "name" => "receipt.pdf", "content_type" => "com.adobe.pdf",
                               "created" => note["created"], "modified" => note["modified"] } ]
    end
    out
  end

  def error(code, message, **extra)
    { "error" => { "code" => code, "message" => message }.merge(extra.stringify_keys) }
  end

  def encode(status, body)
    [ status.to_s, JSON.generate(body) ]
  end
end
