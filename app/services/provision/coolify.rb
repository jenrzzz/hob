require "net/http"

class Provision
  # The slice of Coolify's API that provisioning needs: read an app's env,
  # upsert variables, restart. `transport` is anything that responds to
  # call(method, path, body) → parsed JSON; the default talks to COOLIFY_URL
  # with COOLIFY_TOKEN (a token with write access to the target apps).
  class Coolify
    def self.from_env
      new(url: ENV["COOLIFY_URL"], token: ENV["COOLIFY_TOKEN"])
    end

    def initialize(url: nil, token: nil, transport: nil)
      @transport = transport || Transport.new(url: url, token: token)
    end

    def application(uuid)
      @transport.call(:get, "/applications/#{uuid}", nil)
    end

    # Coolify's env endpoint is POST for a new key and PATCH for an existing
    # one. `secret` names keys whose value the UI should stop showing.
    def set_env(uuid, vars, secret: nil)
      existing = @transport.call(:get, "/applications/#{uuid}/envs", nil).map { |e| e["key"] }
      vars.each do |key, value|
        body = { key: key, value: value, is_preview: false, is_literal: true, is_multiline: false,
                 is_shown_once: Array(secret).include?(key) }
        @transport.call(existing.include?(key) ? :patch : :post, "/applications/#{uuid}/envs", body)
      end
    end

    def restart(uuid)
      @transport.call(:post, "/applications/#{uuid}/restart", nil)
    end

    class Transport
      def initialize(url:, token:)
        raise Provision::Error, "COOLIFY_URL and COOLIFY_TOKEN are not set" if url.blank? || token.blank?

        @base = URI(url.to_s.sub(%r{/+\z}, ""))
        @base.path = "#{@base.path}/api/v1" unless @base.path.end_with?("/api/v1")
        @token = token
      end

      def call(method, path, body)
        uri = @base.dup
        uri.path = "#{@base.path}#{path}"
        request = ::Net::HTTP.const_get(method.to_s.capitalize).new(uri)
        request["Authorization"] = "Bearer #{@token}"
        request["Accept"] = "application/json"
        if body
          request["Content-Type"] = "application/json"
          request.body = body.to_json
        end
        response = ::Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                     open_timeout: 10, read_timeout: 60) { |http| http.request(request) }
        data = parse(response.body)
        return data if response.code.start_with?("2")

        raise Provision::Error, "Coolify #{method.to_s.upcase} #{path}: HTTP #{response.code} #{data['message'] || data['error']}"
      rescue SocketError, SystemCallError, ::Net::OpenTimeout, ::Net::ReadTimeout => e
        raise Provision::Error, "Coolify unreachable at #{@base}: #{e.message}"
      end

      private

      def parse(body)
        JSON.parse(body.presence || "{}")
      rescue JSON::ParserError
        { "message" => body }
      end
    end
  end
end
