require_relative "test_helper"

class WebhookTest < Minitest::Test
  BODY = '{"request":"r1"}'.freeze

  def test_verifies_a_single_signature_and_refuses_the_wrong_secret_body_or_time
    header = Hob::Webhook.sign(secret: "s3cret", body: BODY)
    assert Hob::Webhook.verify(secret: "s3cret", signature: header, body: BODY)
    refute Hob::Webhook.verify(secret: "wrong", signature: header, body: BODY)
    refute Hob::Webhook.verify(secret: "s3cret", signature: header, body: "#{BODY} ")
    refute Hob::Webhook.verify(secret: "s3cret", signature: header, body: BODY, now: Time.now.to_i + 1000)
  end

  # While hob rotates the secret it signs with the old and the new one.
  def test_any_v1_in_an_overlapping_signature_verifies
    t = Time.now.to_i
    old = Hob::Webhook.sign(secret: "old", body: BODY, timestamp: t)
    new = Hob::Webhook.sign(secret: "new", body: BODY, timestamp: t)
    header = "#{old},#{new.sub(/\At=\d+,/, '')}"
    assert Hob::Webhook.verify(secret: "old", signature: header, body: BODY)
    assert Hob::Webhook.verify(secret: "new", signature: header, body: BODY)
    refute Hob::Webhook.verify(secret: "other", signature: header, body: BODY)
  end
end
