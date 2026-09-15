require "openssl"

module Hob
  # The receiving side of the sentinel's webhook venue. hob signs each
  # delivery with the capability's secret:
  #
  #   X-Hob-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>
  #
  # In a Rails surface:
  #
  #   raw = request.raw_post
  #   head :unauthorized unless Hob::Webhook.verify(secret: ENV["HOB_WEBHOOK_SECRET"],
  #                                                 signature: request.headers["X-Hob-Signature"], body: raw)
  #   delivery = JSON.parse(raw)   # request, capability, agent, realm, arguments, reason, decided_by, mission
  #   render json: { added: item }  # any JSON becomes the request's result; non-2xx { error } fails it
  module Webhook
    TOLERANCE = 300

    module_function

    def verify(secret:, signature:, body:, tolerance: TOLERANCE, now: Time.now.to_i)
      parts = signature.to_s.split(",").filter_map { |kv| kv.include?("=") && kv.split("=", 2) }.to_h
      timestamp = parts["t"].to_i
      return false if timestamp.zero? || (now - timestamp).abs > tolerance

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{timestamp}.#{body}")
      given = parts["v1"].to_s
      expected.bytesize == given.bytesize && OpenSSL.fixed_length_secure_compare(expected, given)
    end

    # What hob sends; for a surface's own tests.
    def sign(secret:, body:, timestamp: Time.now.to_i)
      "t=#{timestamp},v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret.to_s, "#{timestamp}.#{body}")}"
    end
  end
end
