require "net/http"

module Consoles
  module Backends
    # jetkvm: a JetKVM, reached through the bridge (KVM.md), a small service
    # on the tailnet that holds the device's WebRTC connection and speaks
    # plain HTTP. The bridge knows nothing of hob; this class is the whole of
    # what hob knows of the bridge. The device's password is the bridge's
    # and never hob's; hob holds a bearer key for the bridge (Console#key).
    #
    #   GET    /v1/status[?probe=1]              → { bridge, device: { version?, video?, usb?, http }, session? }
    #   POST   /v1/sessions { ttl, scale? }      → 201 { id, expires_at, video, screen }
    #   GET    /v1/sessions/:id?screen=1&scale=  → { id, expires_at, video, screen }
    #   POST   /v1/sessions/:id/actions { action, ... } → { id, expires_at, video, screen }
    #   DELETE /v1/sessions/:id                  → 204
    class Jetkvm < Base
      # Tests inject a lambda (verb, url, body, headers) -> [status, body]
      # here, as Browse::Backends::Gofer does, so nothing touches the network.
      class_attribute :transport

      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 50 # a wait step is up to 30 seconds, and opening connects WebRTC first
      CONFIG_KEYS = %w[url key key_env addr].freeze

      def self.config_errors(config)
        errors = []
        unknown = config.keys - CONFIG_KEYS
        errors << "has unknown keys #{unknown.join(', ')} (known: #{CONFIG_KEYS.join(', ')})" if unknown.any?
        errors << "needs a url (http or https): where the bridge listens" unless config["url"].to_s.match?(%r{\Ahttps?://\S+\z})
        errors << "needs a key or a key_env: the bridge's bearer key" if config["key"].blank? && config["key_env"].blank?
        errors << "takes a key or a key_env, not both" if config["key"].present? && config["key_env"].present?
        errors
      end

      def open(ttl:, scale:)
        post("/v1/sessions", { "ttl" => ttl, "scale" => scale }.compact)
      end

      def state(remote_id, scale:)
        get("/v1/sessions/#{escape(remote_id)}", { "screen" => 1, "scale" => scale }.compact)
      end

      def act(remote_id, body)
        post("/v1/sessions/#{escape(remote_id)}/actions", body)
      end

      def close(remote_id)
        request("DELETE", "/v1/sessions/#{escape(remote_id)}")
        true
      end

      # GET /v1/status: the bridge answers, the key is good, and the device
      # answers. Video is known only over a WebRTC connection, which takes
      # the KVM from whoever has it: without a session open, `probe: true`
      # connects for a moment to ask, and without it nothing connects.
      def check(probe: false)
        status = get("/v1/status", probe ? { "probe" => 1 } : nil)
        { "reachable" => true, "bridge" => status["bridge"], "device" => status["device"], "session" => status["session"] }.compact
      end

      private

      def get(path, query = nil)
        path = "#{path}?#{URI.encode_www_form(query)}" if query.present?
        request("GET", path)
      end

      def post(path, body)
        request("POST", path, body)
      end

      def request(verb, path, body = nil)
        key = console.key
        raise Consoles::Unavailable, "#{console.name} has no key: #{key_hint}" if key.blank?

        headers = { "Authorization" => "Bearer #{key}", "Accept" => "application/json" }
        headers["Content-Type"] = "application/json" if body
        status, response = deliver(verb, "#{console.url}#{path}", body && JSON.generate(body), headers)
        data = parse(response)
        return data if status.to_s.start_with?("2")

        raise error_for(status.to_i, data)
      end

      def key_hint
        console.config["key_env"].present? ? "#{console.config['key_env']} is not set in hob's environment" : "set config.key or config.key_env"
      end

      def deliver(verb, url, body, headers)
        (self.class.transport || method(:http)).call(verb, url, body, headers)
      rescue SocketError, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
        raise Consoles::Unavailable, "the bridge is unreachable at #{URI(console.url).host}: #{e.class.name.demodulize}: #{e.message}"
      end

      def http(verb, url, body, headers)
        uri = URI(url)
        req = Net::HTTP.const_get(verb.capitalize).new(uri)
        headers.each { |name, value| req[name] = value }
        req.body = body if body
        response = connection(uri).start { |session| session.request(req) }
        [ response.code, response.body ]
      end

      def connection(uri)
        Net::HTTP.new(uri.host, uri.port).tap do |http|
          http.ipaddr = console.addr if console.addr
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = OPEN_TIMEOUT
          http.read_timeout = READ_TIMEOUT
        end
      end

      def parse(body)
        return {} if body.blank?

        data = JSON.parse(body)
        data.is_a?(Hash) ? data : { "data" => data }
      rescue JSON::ParserError
        { "error" => body.to_s.truncate(200) }
      end

      # The bridge's { error } as one of ours (KVM.md, "In hob").
      def error_for(status, data)
        detail = data["error"].is_a?(String) ? data["error"] : data["error"].to_s.presence
        case status
        when 404 then Consoles::NotFound.new(detail || "the bridge has no such session")
        when 410 then Consoles::Gone.new(detail || "the session is gone")
        when 400, 422 then Consoles::Invalid.new(detail || "the bridge refused the request (HTTP #{status})")
        when 401, 403 then Consoles::Forbidden.new("the bridge refused #{console.name}'s key: #{detail || "HTTP #{status}"}")
        when 409 then Consoles::Unavailable.new(detail || "#{console.name} is in use by another session")
        when 429 then Consoles::Unavailable.new(detail || "the bridge is busy; try again shortly")
        when 500..599 then Consoles::Unavailable.new("the bridge failed with HTTP #{status}#{detail && ": #{detail}"}")
        else Consoles::Error.new("the bridge answered HTTP #{status}#{detail && ": #{detail}"}")
        end
      end

      def escape(id)
        ERB::Util.url_encode(id.to_s)
      end
    end
  end
end
