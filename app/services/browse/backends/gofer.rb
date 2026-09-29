require "net/http"

module Browse
  module Backends
    # gofer: an HTTP server beside a real Chrome on the owner's Mac, driving
    # a profile the owner has logged into. gofer knows nothing of hob; this
    # class is the whole of what hob knows of gofer (its API.md). Its
    # sessions are tabs, its snapshot is the page with a ref on every
    # element, and its keys confine where a tab may go, in the browser.
    #
    # The bearer key is the browser row's (Browser#key). Domains a session
    # is opened with go to gofer, which holds them to the key's own.
    # `update_key_domains` is the one admin exception: it edits a key's
    # domains with GOFER_ADMIN_TOKEN, never browser.key.
    class Gofer < Base
      # Tests inject a lambda (verb, url, body, headers) -> [status, body]
      # here, as Todos::Backends::Omnifocus does, so nothing touches the network.
      class_attribute :transport

      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 60 # a step waits for the page to settle; Amazon can take a while
      CONFIG_KEYS = %w[url key key_env addr domains].freeze

      def self.config_errors(config)
        errors = []
        unknown = config.keys - CONFIG_KEYS
        errors << "has unknown keys #{unknown.join(', ')} (known: #{CONFIG_KEYS.join(', ')})" if unknown.any?
        errors << "needs a url (http or https): where gofer listens" unless config["url"].to_s.match?(%r{\Ahttps?://\S+\z})
        errors << "needs a key or a key_env: gofer's bearer key" if config["key"].blank? && config["key_env"].blank?
        errors << "takes a key or a key_env, not both" if config["key"].present? && config["key_env"].present?
        if config.key?("domains") && !(config["domains"].is_a?(Array) && config["domains"].all? { |d| d.is_a?(String) && d.present? })
          errors << "domains must be an array of domain names"
        end
        errors
      end

      def open(url:, domains:, ttl:, screenshot:, max_chars:)
        body = { "url" => url, "screenshot" => screenshot, "max_chars" => max_chars }
        body["domains"] = domains if domains.present?
        body["ttl"] = ttl if ttl
        post("/v1/sessions", body)
      end

      def state(remote_id, screenshot:, max_chars:)
        get("/v1/sessions/#{escape(remote_id)}", { "screenshot" => screenshot ? 1 : 0, "max_chars" => max_chars }.compact)
      end

      def act(remote_id, body)
        post("/v1/sessions/#{escape(remote_id)}/actions", body)
      end

      def close(remote_id)
        delete("/v1/sessions/#{escape(remote_id)}")
        true
      end

      # GET /v1/status: gofer answers, the key is good, and here is its Chrome.
      def check
        status = get("/v1/status")
        { "reachable" => true, "gofer" => status["gofer"], "driver" => status["browser"], "sessions" => status["sessions"],
          "limits" => status["limits"], "gofer_key" => status["key"] }.compact
      end

      # PATCH /v1/keys/:name (BROWSE.md's admin path, not a browsing
      # session): widens or narrows a key's domains without rotating its
      # token. Authenticated with GOFER_ADMIN_TOKEN, a household-admin
      # credential separate from any browser row's own bearer key — this
      # never touches browser.key. `actor`, when given, is gofer's own
      # X-Admin-Actor audit field.
      def update_key_domains(name, domains, admin_token:, actor: nil)
        raise Browse::Unavailable, "no GOFER_ADMIN_TOKEN configured" if admin_token.blank?

        headers = { "Authorization" => "Bearer #{admin_token}", "Accept" => "application/json", "Content-Type" => "application/json" }
        headers["X-Admin-Actor"] = actor if actor.present?
        status, response = deliver("PATCH", "#{browser.url}/v1/keys/#{escape(name)}", JSON.generate({ "domains" => domains }), headers)
        data = parse(response)
        return data if status.to_s.start_with?("2")

        raise admin_error_for(status.to_i, data)
      end

      private

      def get(path, query = nil)
        path = "#{path}?#{URI.encode_www_form(query)}" if query.present?
        request("GET", path)
      end

      def post(path, body)
        request("POST", path, body)
      end

      def delete(path)
        request("DELETE", path)
      end

      def request(verb, path, body = nil)
        key = browser.key
        raise Browse::Unavailable, "#{browser.name} has no key: #{key_hint}" if key.blank?

        headers = { "Authorization" => "Bearer #{key}", "Accept" => "application/json" }
        headers["Content-Type"] = "application/json" if body
        status, response = deliver(verb, "#{browser.url}#{path}", body && JSON.generate(body), headers)
        data = parse(response)
        return data if status.to_s.start_with?("2")

        raise error_for(status.to_i, data)
      end

      def key_hint
        browser.config["key_env"].present? ? "#{browser.config['key_env']} is not set in hob's environment" : "set config.key or config.key_env"
      end

      def deliver(verb, url, body, headers)
        (self.class.transport || method(:http)).call(verb, url, body, headers)
      rescue SocketError, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
        raise Browse::Unavailable, "gofer unreachable at #{URI(browser.url).host}: #{e.class.name.demodulize}: #{e.message}"
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
          http.ipaddr = browser.addr if browser.addr
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

      # gofer's { error } as one of ours.
      def error_for(status, data)
        detail = data["error"].is_a?(String) ? data["error"] : data["error"].to_s.presence
        case status
        when 404 then Browse::NotFound.new(detail || "gofer has no such session")
        when 410 then Browse::Gone.new(detail || "the session is gone")
        when 400, 422 then Browse::Invalid.new(detail || "gofer refused the request (HTTP #{status})")
        when 401, 403 then Browse::Forbidden.new("gofer refused #{browser.name}'s key: #{detail || "HTTP #{status}"}")
        when 429 then Browse::Unavailable.new(detail || "gofer has no free session; try again shortly")
        when 502 then Browse::Unavailable.new(detail || "the page could not be opened")
        when 500..599 then Browse::Unavailable.new("gofer failed with HTTP #{status}#{detail && ": #{detail}"}")
        else Browse::Error.new("gofer answered HTTP #{status}#{detail && ": #{detail}"}")
        end
      end

      def escape(id)
        ERB::Util.url_encode(id.to_s)
      end

      # gofer's { error } for the admin key-patch route: only 400, 401 and
      # 404 are documented (API.md, "Key management (admin)").
      def admin_error_for(status, data)
        detail = data["error"].is_a?(String) ? data["error"] : nil
        case status
        when 404 then Browse::NotFound.new(detail || "gofer has no key by that name")
        when 400 then Browse::Invalid.new(detail || "gofer rejected the domains (HTTP 400)")
        when 401 then Browse::Forbidden.new(detail || "gofer refused the admin credentials")
        else Browse::Error.new("gofer answered HTTP #{status}#{detail && ": #{detail}"}")
        end
      end
    end
  end
end
