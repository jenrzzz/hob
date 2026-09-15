require "net/http"
require "openssl"

module Sentinel
  # The webhook venue: hob POSTs the approved request to the surface that
  # registered the capability, signed with the capability's secret so the
  # surface knows the sentinel, not the agent, is calling. The surface
  # answers 2xx with a JSON result (any shape; it is stored as-is) or a
  # non-2xx with { error } to fail the request.
  #
  #   X-Hob-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<body>")>
  module Webhook
    class Error < StandardError; end

    TOLERANCE = 300

    # Tests inject a lambda (url, body, headers) -> [status, body] here.
    mattr_accessor :transport

    module_function

    def deliver(capability, request, transport: nil)
      body = JSON.generate(
        request: request.id, capability: capability.name, agent: request.principal.name,
        realm: request.realm, arguments: request.arguments, reason: request.reason,
        decided_by: request.decided_by, mission: request.on_mission_id
      )
      timestamp = Time.now.to_i
      headers = { "Content-Type" => "application/json", "Accept" => "application/json",
                  "X-Hob-Signature" => signature(capability.config["secret"], timestamp, body),
                  "X-Hob-Request" => request.id }
      status, response_body = (transport || Webhook.transport || method(:post)).call(capability.config["url"], body, headers)
      data = parse(response_body)
      return data if status.to_s.start_with?("2")

      raise Error, "#{capability.name} webhook answered HTTP #{status}: #{data.is_a?(Hash) ? data['error'] || data['message'] : data}"
    end

    def signature(secret, timestamp, body)
      "t=#{timestamp},v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret.to_s, "#{timestamp}.#{body}")}"
    end

    # The receiving side (mirrored in the gem as Hob::Webhook.verify).
    def verify(secret, header, body, tolerance: TOLERANCE, now: Time.now.to_i)
      parts = header.to_s.split(",").filter_map { |kv| kv.include?("=") && kv.split("=", 2) }.to_h
      timestamp = parts["t"].to_i
      return false if timestamp.zero? || (now - timestamp).abs > tolerance

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{timestamp}.#{body}")
      ActiveSupport::SecurityUtils.secure_compare(expected, parts["v1"].to_s)
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
