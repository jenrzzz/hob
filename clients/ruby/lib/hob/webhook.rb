require "openssl"

module Hob
  # The receiving side of the sentinel's webhook venue. hob signs each
  # delivery with the capability's secret:
  #
  #   X-Hob-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>.<raw body>")>
  #
  # While hob rotates the secret it signs with both the old and the new one
  # (two v1 entries) for a while, so a surface that has not yet restarted
  # with the new secret still verifies. Any matching v1 is accepted.
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
      pairs = signature.to_s.split(",").filter_map { |kv| kv.include?("=") && kv.strip.split("=", 2) }
      timestamp = pairs.reverse.find { |key, _| key == "t" }&.last.to_i
      return false if timestamp.zero? || (now - timestamp).abs > tolerance

      expected = OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "#{timestamp}.#{body}")
      pairs.select { |key, _| key == "v1" }.any? do |_, given|
        given = given.to_s
        expected.bytesize == given.bytesize && OpenSSL.fixed_length_secure_compare(expected, given)
      end
    end

    # What hob sends; for a surface's own tests.
    def sign(secret:, body:, timestamp: Time.now.to_i)
      "t=#{timestamp},v1=#{OpenSSL::HMAC.hexdigest('SHA256', secret.to_s, "#{timestamp}.#{body}")}"
    end
  end
end
