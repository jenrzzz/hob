require "net/http"
require "openssl"

module Sentinel
  # The webhook venue: hob POSTs the approved request to the surface that
  # registered the capability, signed with the capability's secret so the
  # surface knows the sentinel, not the agent, is calling. A plugin's row is
  # addressed by the plugin's own name for it (Capability#remote_name), not
  # the name hob offers it under, and the body says which installation. The surface
  # answers 2xx with a JSON result (any shape; it is stored as-is) or a
  # non-2xx with { error } to fail the request.
  #
  #   X-Hob-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<body>")>
  #
  # While a rotated secret overlaps the one before it (SurfaceCapabilities
  # #rotate: config.previous_secret, until config.previous_secret_until or
  # the plugin confirms the new one),
  # each delivery carries one v1 per secret, the old first and the new last,
  # so a surface holding either one verifies it. A verifier reading only the
  # last v1 (the gem before it accepted any) sees the new secret's.
  module Webhook
    class Error < StandardError; end

    TOLERANCE = 300

    # Tests inject a lambda (url, body, headers) -> [status, body] here.
    mattr_accessor :transport

    module_function

    def deliver(capability, request, transport: nil)
      # Checked again here, not only at the gate: a request a person approved
      # before its plugin was quarantined is not delivered after.
      plugin = capability.plugin_id && Plugin.includes(:principal, :owner).find(capability.plugin_id)
      if (problem = plugin&.unavailable_to(request.principal))
        raise Error, problem
      end
      # And its contract, as it is now (PLUGINS.md, section 7): not suspended
      # since, and still the revision the request was asked against.
      current = Capability.find(capability.id)
      raise Error, "#{current.name} is suspended: #{current.suspended_reason}" if current.suspended?
      if request.contract_revision && request.contract_revision != current.contract_revision
        raise Error, "#{current.name}'s contract changed (revision #{request.contract_revision} to #{current.contract_revision}) " \
                     "after this was asked for; ask again"
      end

      # The plugin's own name for it (PLUGINS.md, Phase 1c), and which of its
      # installations hob is calling as.
      body = JSON.generate(
        request: request.id, capability: capability.remote_name || capability.name, installation: plugin&.namespace,
        agent: request.principal.name,
        realm: request.realm, arguments: request.arguments, reason: request.reason,
        decided_by: request.decided_by, mission: request.on_mission_id
      )
      timestamp = Time.now.to_i
      headers = { "Content-Type" => "application/json", "Accept" => "application/json",
                  "X-Hob-Signature" => signature(signing_secrets(capability.config), timestamp, body),
                  "X-Hob-Request" => request.id }
      status, response_body = (transport || Webhook.transport || method(:post)).call(capability.config["url"], body, headers)
      data = parse(response_body)
      return data if status.to_s.start_with?("2")

      raise Error, "#{capability.name} webhook answered HTTP #{status}: #{data.is_a?(Hash) ? data['error'] || data['message'] : data}"
    end

    # One secret or several (oldest first).
    def signature(secrets, timestamp, body)
      sigs = Array(secrets).map { |secret| "v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret.to_s, "#{timestamp}.#{body}")}" }
      "t=#{timestamp},#{sigs.join(',')}"
    end

    # The secret deliveries are signed with, preceded by the one it replaced
    # while their overlap lasts: until previous_secret_until, or, with none,
    # until the plugin's signed manifest says it holds the new one
    # (SurfaceCapabilities retires the old one then).
    def signing_secrets(config, now: Time.current)
      previous = config["previous_secret"].presence
      until_at = config["previous_secret_until"].presence && Time.zone.parse(config["previous_secret_until"].to_s)
      overlapping = previous && (until_at.nil? || now < until_at) && previous != config["secret"]
      [ (previous if overlapping), config["secret"] ].compact
    end

    # The receiving side (mirrored in the gem as Hob::Webhook.verify): any
    # v1 made with this secret will do.
    def verify(secret, header, body, tolerance: TOLERANCE, now: Time.now.to_i)
      pairs = header.to_s.split(",").filter_map { |kv| kv.include?("=") && kv.strip.split("=", 2) }
      timestamp = pairs.reverse.find { |key, _| key == "t" }&.last.to_i
      return false if timestamp.zero? || (now - timestamp).abs > tolerance

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{timestamp}.#{body}")
      pairs.select { |key, _| key == "v1" }.any? { |_, given| ActiveSupport::SecurityUtils.secure_compare(expected, given.to_s) }
    end

    def post(url, body, headers)
      uri = URI(url)
      req = Net::HTTP::Post.new(uri)
      headers.each { |k, v| req[k] = v }
      req.body = body
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                 open_timeout: 10, read_timeout: 60) { |http| http.request(req) }
      [ response.code, response.body ]
    rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, IOError => e
      raise Error, "webhook unreachable at #{uri.host}: #{e.message}"
    end

    def parse(body)
      return {} if body.blank?

      JSON.parse(body)
    rescue JSON::ParserError
      { "content" => body }
    end
  end
end
