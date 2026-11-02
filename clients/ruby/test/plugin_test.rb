require_relative "test_helper"

# The gem's signatures must be exactly what hob's PluginSignature verifies;
# hob's own test suite checks the same vectors from its side.
class PluginTest < Minitest::Test
  KEY = "k" * 64

  def test_a_manifest_signature_is_bound_to_the_installation_revision_nonce_delivery_secret_and_body
    header = Hob::Plugin.sign_manifest(body: "{}", nonce: "n1", revision: 7, key: KEY, installation: "mise", delivery_secret: "s3cret")
    kid = Hob::Plugin.delivery_key_id("s3cret")
    expected = OpenSSL::HMAC.hexdigest("SHA256", KEY, [ "hob-manifest.v1", "mise", 7, "n1", kid, "{}" ].join("\n"))
    assert_equal "rev=7,kid=#{kid},v1=#{expected}", header
    assert_equal 16, kid.length
    assert_equal "", Hob::Plugin.delivery_key_id(nil)
    assert_raises(Hob::Plugin::Error) { Hob::Plugin.sign_manifest(body: "{}", nonce: "n", revision: 1, key: "", installation: "mise") }
    assert_raises(Hob::Plugin::Error) { Hob::Plugin.sign_manifest(body: "{}", nonce: "n", revision: "1", key: KEY, installation: "mise") }
  end

  def test_announce_posts_a_signed_ping
    sent = nil
    transport = lambda do |url, body, headers, _timeout|
      sent = [ url, body, headers ]
      [ "202", '{"queued":true}' ]
    end
    assert Hob::Plugin.announce(url: "https://hob.test/", key: KEY, installation: "mise", transport: transport)

    url, body, headers = sent
    assert_equal "https://hob.test/v1/plugins/announce", url
    assert_equal "mise", headers["X-Hob-Installation"]
    t = headers["X-Hob-Signature"][/\At=(\d+)/, 1]
    expected = OpenSSL::HMAC.hexdigest("SHA256", KEY, [ "hob-announce.v1", "mise", t, body ].join("\n"))
    assert_equal "t=#{t},v1=#{expected}", headers["X-Hob-Signature"]

    refused = ->(*) { [ "401", '{"error":"signature does not verify"}' ] }
    error = assert_raises(Hob::Plugin::Error) { Hob::Plugin.announce(url: "https://hob.test", key: KEY, installation: "mise", transport: refused) }
    assert_match(/401/, error.message)
    assert_raises(Hob::Plugin::Error) { Hob::Plugin.announce(url: nil, key: KEY, installation: "mise") }
  end
end
