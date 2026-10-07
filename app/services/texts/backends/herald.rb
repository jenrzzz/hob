require "net/http"

module Texts
  module Backends
    # Messages, by way of herald: an HTTP server on the owner's Mac that reads
    # the Messages app's own database and sends by asking the app to. herald
    # knows nothing of hob; this class is the whole of what hob knows of
    # herald (its API.md).
    #
    #   chat     ← a herald chat        message ← a herald message
    #   ids, chat_id, and reply_to get "<backend>:" in front; times come
    #   back in the household's zone; herald's `seq` stays behind
    #
    # The bearer key is the backend row's (TextBackend#key). A key herald has
    # *scoped* to some chats or people sees only those, and may send only to
    # them; that is how one family group chat is shared with household
    # agents (TEXTS.md).
    class Herald < Base
      # Tests inject a lambda (verb, url, body, headers) -> [status, body]
      # here, as they do with Todos::Backends::Omnifocus.transport, so nothing
      # in the suite touches the network.
      class_attribute :transport

      OPEN_TIMEOUT = 5
      # A send waits for Messages and then for the message to show up in its
      # database (HERALD_SEND_WAIT, 10 seconds by default) before answering.
      READ_TIMEOUT = 30
      POLL_LIMIT = 100
      CONFIG_KEYS = %w[url key key_env addr read_only].freeze
      ENV_NAME = /\A[A-Z_][A-Z0-9_]*\z/

      def self.config_errors(config)
        errors = []
        unknown = config.keys - CONFIG_KEYS
        errors << "has unknown keys #{unknown.join(', ')} (known: #{CONFIG_KEYS.join(', ')})" if unknown.any?
        errors << "needs a url (http or https): where herald listens" unless config["url"].to_s.match?(%r{\Ahttps?://\S+\z})
        errors << "needs a key or a key_env: herald's bearer key" if config["key"].blank? && config["key_env"].blank?
        errors << "takes a key or a key_env, not both" if config["key"].present? && config["key_env"].present?
        # A key_env comes back out in every response, so a key put there by
        # mistake would be published. The value is not echoed in the error.
        if config["key_env"].present? && !config["key_env"].to_s.match?(ENV_NAME)
          errors << "key_env names an environment variable (like HERALD_KEY); the key itself goes in key"
        end
        errors << "addr is an address to connect to (a tailnet IP)" if config.key?("addr") && !config["addr"].is_a?(String)
        errors << "read_only is true or false" if config.key?("read_only") && ![ true, false ].include?(config["read_only"])
        errors
      end

      def chats(filter, limit)
        query = { "q" => filter["q"], "active_after" => utc(filter["active_after"]), "limit" => limit }.compact
        Array(get("/v1/chats", query)["chats"]).map { |chat| chat(chat) }
      end

      def messages(filter, limit)
        query = { "chat" => filter["chat"], "from" => filter["from"], "q" => filter["q"], "after" => utc(filter["after"]),
                  "before" => utc(filter["before"]), "unread" => filter["unread"], "limit" => limit }.compact
        data = get("/v1/messages", query)
        { "messages" => Array(data["messages"]).map { |message| message(message) }, "truncated" => data["truncated"] == true,
          "searched_back_to" => parse_time(data["searched_back_to"]) }
      end

      # herald's cursor is a number that only grows; with none, herald says
      # where it is now and hands back nothing.
      def poll(state, from_me:)
        query = { "since" => state, "from_me" => from_me, "limit" => POLL_LIMIT }.compact
        data = get("/v1/changes", query)
        { "state" => data["cursor"].to_s, "messages" => Array(data["messages"]).map { |message| message(message) },
          "more" => data["more"] == true }
      end

      # 201: Messages has it, and here it is. 202: Messages took it, and it
      # had not shown up in the database yet; it is usually on its way.
      def send_message(chat:, to:, text:)
        raise Texts::Invalid, "#{backend.name} is read-only: it may not send" if backend.read_only?

        status, data = request("POST", "/v1/messages", { "chat" => chat, "to" => to, "text" => text }.compact)
        if status == 202 || data["pending"]
          { "status" => "pending", "chat_id" => prefixed(data["chat_id"] || chat) }
        else
          sent = message(data["message"].is_a?(Hash) ? data["message"] : data)
          { "status" => "sent", "message" => sent, "chat_id" => sent["chat_id"] }
        end
      end

      # GET /v1/status: herald answers, it can read the Messages database,
      # and the key is good.
      def check
        status = get("/v1/status")
        { "reachable" => true, "herald" => status["herald"], "macos" => status["macos"], "database" => status["database"],
          "contacts" => status["contacts"], "herald_key" => status["key"], "now" => status["now"] }.compact
      end

      private

      # --- herald → hob ---

      def chat(chat)
        { "id" => prefixed(chat["id"]), "backend" => backend.name, "identifier" => chat["identifier"],
          "service" => chat["service"], "group" => chat["group"] == true, "name" => chat["name"],
          "display_name" => chat["display_name"], "participants" => Array(chat["participants"]).map { |p| person(p) },
          "last_message_at" => shown_time(chat["last_message_at"]), "unread" => chat["unread"].to_i,
          "_last" => parse_time(chat["last_message_at"]) }
      end

      def message(message)
        { "id" => prefixed(message["id"]), "backend" => backend.name, "chat_id" => prefixed(message["chat_id"]),
          "from_me" => message["from_me"] == true, "sender" => message["sender"].is_a?(Hash) ? person(message["sender"]) : nil,
          "text" => message["text"], "sent_at" => shown_time(message["sent_at"]), "read_at" => shown_time(message["read_at"]),
          "delivered_at" => shown_time(message["delivered_at"]), "read" => message["read"] == true,
          "service" => message["service"], "reply_to" => prefixed(message["reply_to"]),
          "edited" => message["edited"] == true, "unsent" => message["unsent"] == true,
          "attachments" => Array(message["attachments"]).map { |a| a.slice("name", "type", "size") },
          "reactions" => Array(message["reactions"]).map { |r| reaction(r) },
          "_sent" => parse_time(message["sent_at"]), "_seq" => message["seq"].to_i }
      end

      def person(person)
        { "handle" => person["handle"], "name" => person["name"] }
      end

      def reaction(reaction)
        { "reaction" => reaction["reaction"], "emoji" => reaction["emoji"], "from_me" => reaction["from_me"] == true,
          "from" => reaction["from"].is_a?(Hash) ? person(reaction["from"]) : nil }
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
        raise Texts::Unavailable, "#{backend.name} has no key: #{key_hint}" if key.blank?

        headers = { "Authorization" => "Bearer #{key}", "Accept" => "application/json" }
        headers["Content-Type"] = "application/json" if body
        status, response = deliver(verb, "#{backend.url}#{path}", body && JSON.generate(body), headers)
        data = parse(response)
        return [ status.to_i, data ] if status.to_s.start_with?("2")

        raise error_for(status.to_i, data)
      end

      def key_hint
        backend.config["key_env"].present? ? "#{backend.config['key_env']} is not set in hob's environment" : "set config.key or config.key_env"
      end

      # Whatever goes wrong on the way there is the same answer: not now.
      def deliver(verb, url, body, headers)
        (self.class.transport || method(:http)).call(verb, url, body, headers)
      rescue SocketError, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
        raise Texts::Unavailable, "herald unreachable at #{URI(backend.url).host}: #{e.class.name.demodulize}: #{e.message}"
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
      # Host and SNI, as the omnifocus adapter does it. No retries: Net::HTTP
      # would quietly send a request a second time after a read timeout, and
      # a text sent twice is a text sent twice.
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

      # herald's { error: { code, kind?, message } } as one of ours.
      def error_for(status, data)
        error = data["error"].is_a?(Hash) ? data["error"] : { "message" => data["error"] }
        detail = error["message"].presence || error["code"].presence
        case status
        when 404 then Texts::NotFound.new(detail || "herald found nothing there")
        when 400, 409, 422 then Texts::Invalid.new(detail || "herald refused the request (HTTP #{status})")
        when 401, 403 then Texts::Forbidden.new("herald refused #{backend.name}'s key: #{detail || "HTTP #{status}"}")
        when 503 then Texts::Unavailable.new(detail || "herald cannot reach Messages")
        when 500..599 then Texts::Unavailable.new("herald failed with HTTP #{status}#{detail && ": #{detail}"}")
        else Texts::Error.new("herald answered HTTP #{status}#{detail && ": #{detail}"}")
        end
      end
    end
  end
end
