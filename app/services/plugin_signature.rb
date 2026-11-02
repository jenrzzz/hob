require "openssl"

# What a plugin installation signs with its key (HOB_PLUGIN_KEY; PLUGINS.md,
# section 4), mirrored in the gem as Hob::Plugin. Each message has its own
# context string, so a signature over one can never be passed off as another.
#
# A manifest, in answer to hob's GET /hob/capabilities, which carries
# X-Hob-Installation: <namespace> and X-Hob-Nonce: <hex>:
#
#   X-Hob-Manifest-Signature: rev=<int>,kid=<delivery key id>,v1=<hex HMAC-SHA256(key, payload)>
#   payload = "hob-manifest.v1\n<namespace>\n<rev>\n<nonce>\n<kid>\n<raw body>"
#
# `rev` is the plugin's own revision, which never goes down (its boot time
# will do); `kid` is the id of the delivery secret it holds now
# (delivery_key_id), which is how hob learns a rotation has landed. The
# nonce is fresh per fetch, so an old signed answer cannot be replayed.
#
# An announcement, POSTed to hob's /v1/plugins/announce:
#
#   X-Hob-Installation: <namespace>
#   X-Hob-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(key, "hob-announce.v1\n<namespace>\n<t>\n<raw body>")>
module PluginSignature
  TOLERANCE = 300
  MANIFEST = "hob-manifest.v1".freeze
  ANNOUNCE = "hob-announce.v1".freeze

  Manifest = Struct.new(:revision, :kid, :key, keyword_init: true)

  module_function

  # Which delivery secret a plugin holds, without saying it.
  def delivery_key_id(secret)
    return "" if secret.blank?

    OpenSSL::Digest::SHA256.hexdigest("hob-delivery-key.v1\n#{secret}")[0, 16]
  end

  def sign_manifest(key:, namespace:, revision:, nonce:, kid:, body:)
    "rev=#{revision},kid=#{kid},v1=#{hmac(key, [ MANIFEST, namespace, revision, nonce, kid, body ])}"
  end

  # -> Manifest (with whichever of `keys` signed it), or nil.
  def verify_manifest(header, keys:, namespace:, nonce:, body:)
    parts = pairs(header)
    revision = parts["rev"].to_s
    return nil unless revision.match?(/\A\d{1,18}\z/)

    kid = parts["kid"].to_s
    payload = [ MANIFEST, namespace, revision, nonce, kid, body ]
    key = Array(keys).compact_blank.find { |candidate| match?(hmac(candidate, payload), parts["v1"]) }
    key && Manifest.new(revision: revision.to_i, kid: kid, key: key)
  end

  def sign_announcement(key:, namespace:, body:, timestamp: Time.now.to_i)
    "t=#{timestamp},v1=#{hmac(key, [ ANNOUNCE, namespace, timestamp, body ])}"
  end

  # -> the key among `keys` that signed it, or nil.
  def verify_announcement(header, keys:, namespace:, body:, now: Time.now.to_i, tolerance: TOLERANCE)
    parts = pairs(header)
    timestamp = parts["t"].to_i
    return nil if timestamp.zero? || (now - timestamp).abs > tolerance

    Array(keys).compact_blank.find { |key| match?(hmac(key, [ ANNOUNCE, namespace, timestamp, body ]), parts["v1"]) }
  end

  def hmac(key, parts)
    OpenSSL::HMAC.hexdigest("SHA256", key.to_s, parts.join("\n"))
  end

  def pairs(header)
    header.to_s.split(",").filter_map { |kv| kv.include?("=") && kv.strip.split("=", 2) }.to_h
  end

  def match?(expected, given)
    given = given.to_s
    expected.bytesize == given.bytesize && ActiveSupport::SecurityUtils.secure_compare(expected, given)
  end
end
