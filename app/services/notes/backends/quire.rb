require "net/http"

module Notes
  module Backends
    # Notes, by way of quire: an HTTP server on the owner's Mac that asks the
    # Notes app itself, through its scripting interface, for everything it
    # reads and writes. quire knows nothing of hob; this class is the whole
    # of what hob knows of quire (its API.md).
    #
    #   folder ← a quire folder        note ← a quire note
    #   ids, a folder's parent, and a note's folder get "<backend>:" in front;
    #   times come back in the household's zone
    #
    # The bearer key is the backend row's (NoteBackend#key). A key quire has
    # *scoped* to some folders sees only those (and the folders inside
    # them), and may write only there; that is how one household folder is
    # shared with household agents (NOTES.md).
    class Quire < Base
      # Tests inject a lambda (verb, url, body, headers) -> [status, body]
      # here, as they do with Texts::Backends::Herald.transport, so nothing
      # in the suite touches the network.
      class_attribute :transport

      OPEN_TIMEOUT = 5
      # quire waits up to QUIRE_TIMEOUT (60 seconds by default) for Notes,
      # and a search that reads every note's text in a big library is slow.
      READ_TIMEOUT = 65
      CONFIG_KEYS = %w[url key key_env addr read_only].freeze
      ENV_NAME = /\A[A-Z_][A-Z0-9_]*\z/

      def self.config_errors(config)
        errors = []
        unknown = config.keys - CONFIG_KEYS
        errors << "has unknown keys #{unknown.join(', ')} (known: #{CONFIG_KEYS.join(', ')})" if unknown.any?
        errors << "needs a url (http or https): where quire listens" unless config["url"].to_s.match?(%r{\Ahttps?://\S+\z})
        errors << "needs a key or a key_env: quire's bearer key" if config["key"].blank? && config["key_env"].blank?
        errors << "takes a key or a key_env, not both" if config["key"].present? && config["key_env"].present?
        # A key_env comes back out in every response, so a key put there by
        # mistake would be published. The value is not echoed in the error.
        if config["key_env"].present? && !config["key_env"].to_s.match?(ENV_NAME)
          errors << "key_env names an environment variable (like QUIRE_KEY); the key itself goes in key"
        end
        errors << "addr is an address to connect to (a tailnet IP)" if config.key?("addr") && !config["addr"].is_a?(String)
        errors << "read_only is true or false" if config.key?("read_only") && ![ true, false ].include?(config["read_only"])
        errors
      end

      def folders(filter)
        Array(get("/v1/folders", { "q" => filter["q"] }.compact)["folders"]).map { |folder| folder(folder) }
      end

      # quire answers a page and the total; more than the page is truncated.
      def notes(filter, limit)
        query = { "folder" => filter["folder"], "q" => filter["q"], "tag" => filter["tag"],
                  "modified_after" => utc(filter["modified_after"]), "modified_before" => utc(filter["modified_before"]),
                  "include" => ("snippet" if filter["snippet"]), "sort" => "-modified", "limit" => limit }.compact
        data = get("/v1/notes", query)
        found = Array(data["notes"])
        { "notes" => found.map { |note| shaped(note) }, "truncated" => data["total"].to_i > found.size }
      end

      def note(id)
        shaped(get("/v1/notes/#{escape(id)}"))
      end

      def create(fields)
        shaped(request("POST", "/v1/notes", fields.slice("folder", "title", "text", "html")).last)
      end

      def update(id, fields)
        shaped(request("PATCH", "/v1/notes/#{escape(id)}", fields.slice("title", "text", "html", "append", "folder")).last)
      end

      # GET /v1/status: quire answers, it can reach Notes, and the key is good.
      def check
        status = get("/v1/status")
        { "reachable" => true, "quire" => status["quire"], "notes_app" => status["notes_app"], "counts" => status["counts"],
          "quire_key" => status["key"], "now" => status["now"] }.compact
      end

      private

      # --- quire → hob ---

      def folder(folder)
        { "id" => prefixed(folder["id"]), "backend" => backend.name, "name" => folder["name"], "path" => folder["path"],
          "account" => folder.dig("account", "name"), "parent_id" => prefixed(folder.dig("parent", "id")),
          "shared" => folder["shared"] == true, "note_count" => folder["note_count"].to_i, "folder_count" => folder["folder_count"].to_i }
      end

      # A note's text, html, and attachments come only from a single note or
      # a write, and are left out of a listing rather than shown as null.
      def shaped(note)
        note = {} unless note.is_a?(Hash)
        folder = note["folder"].is_a?(Hash) ? note["folder"] : {}
        out = { "id" => prefixed(note["id"]), "backend" => backend.name, "title" => note["title"],
                "folder" => { "id" => prefixed(folder["id"]), "name" => folder["name"], "path" => folder["path"] },
                "account" => note.dig("account", "name"), "created" => shown_time(note["created"]),
                "modified" => shown_time(note["modified"]), "locked" => note["locked"] == true, "shared" => note["shared"] == true }
        # In Recently Deleted: readable by id, and back in Notes' hands.
        out["folder"]["deleted"] = true if folder["deleted"] == true
        %w[snippet tags text html].each { |key| out[key] = note[key] if note.key?(key) }
        out["attachments"] = Array(note["attachments"]).map { |a| a.slice("name", "content_type") } if note.key?("attachments")
        out.merge("_modified" => parse_time(note["modified"]))
      end

      def utc(time)
        time&.utc&.iso8601
      end

      # --- the wire ---

      def get(path, query = nil)
        path = "#{path}?#{URI.encode_www_form(query)}" if query.present?
        request("GET", path).last
      end

      def request(verb, path, body = nil)
        key = backend.key
        raise Notes::Unavailable, "#{backend.name} has no key: #{key_hint}" if key.blank?

        headers = { "Authorization" => "Bearer #{key}", "Accept" => "application/json" }
        headers["Content-Type"] = "application/json" if body
        status, response = deliver(verb, "#{backend.url}#{path}", body && JSON.generate(body), headers)
        data = parse(response)
        return [ status.to_i, data ] if status.to_s.start_with?("2")

        raise error_for(status.to_i, data)
      end

      # Notes' ids are URLs themselves (x-coredata://…/ICNote/p4021): the
      # whole of one is one path segment, slashes and all.
      def escape(segment)
        ERB::Util.url_encode(segment.to_s)
      end

      def key_hint
        backend.config["key_env"].present? ? "#{backend.config['key_env']} is not set in hob's environment" : "set config.key or config.key_env"
      end

      # Whatever goes wrong on the way there is the same answer: not now.
      def deliver(verb, url, body, headers)
        (self.class.transport || method(:http)).call(verb, url, body, headers)
      rescue SocketError, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
        raise Notes::Unavailable, "quire unreachable at #{URI(backend.url).host}: #{e.class.name.demodulize}: #{e.message}"
      end

      def http(verb, url, body, headers)
        uri = URI(url)
        req = Net::HTTP.const_get(verb.capitalize).new(uri)
        headers.each { |name, value| req[name] = value }
        req.body = body if body
        response = connection(uri).start { |session| session.request(req) }
        [ response.code, response.body ]
      end

      # `addr` pins the address to connect to; the hostname still goes out as
      # Host and SNI. No retries: Net::HTTP would quietly send a request a
      # second time after a read timeout, and an append made twice is twice
      # in the note.
      def connection(uri)
        Net::HTTP.new(uri.host, uri.port).tap do |http|
          http.ipaddr = backend.addr if backend.addr
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = OPEN_TIMEOUT
          http.read_timeout = READ_TIMEOUT
          http.max_retries = 0
        end
      end

      def parse(body)
        return {} if body.blank?

        data = JSON.parse(body)
        data.is_a?(Hash) ? data : { "data" => data }
      rescue JSON::ParserError
        { "error" => { "message" => body.to_s.truncate(200) } }
      end

      # quire's { error: { code, kind?, message, candidates? } } as one of ours.
      def error_for(status, data)
        error = data["error"].is_a?(Hash) ? data["error"] : { "message" => data["error"] }
        detail = error["message"].presence || error["code"].presence
        if status == 409 && error["candidates"].is_a?(Array)
          names = error["candidates"].filter_map { |c| c.is_a?(Hash) ? (c["path"] || c["name"]) : c.to_s }.first(10)
          detail = "#{detail} (candidates: #{names.join('; ')}; use a folder id from note.folders)" if names.any?
        end
        case status
        when 404 then Notes::NotFound.new(detail || "quire found nothing there")
        when 400, 409, 413, 422 then Notes::Invalid.new(detail || "quire refused the request (HTTP #{status})")
        when 401, 403 then Notes::Forbidden.new("quire refused #{backend.name}'s key: #{detail || "HTTP #{status}"}")
        when 503 then Notes::Unavailable.new(detail || "quire cannot reach Notes")
        when 500..599 then Notes::Unavailable.new("quire failed with HTTP #{status}#{detail && ": #{detail}"}")
        else Notes::Error.new("quire answered HTTP #{status}#{detail && ": #{detail}"}")
        end
      end
    end
  end
end
