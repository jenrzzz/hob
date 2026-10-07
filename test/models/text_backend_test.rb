require "test_helper"

# A text backend is a row (TEXTS.md): whose messages, in which realm,
# reached how; and the key in it stays in it.
class TextBackendTest < ActiveSupport::TestCase
  HERALD = { "url" => "http://mini.test:8379", "key_env" => "HERALD_KEY" }.freeze

  def build(config: HERALD, **attrs)
    TextBackend.new({ name: "jenner-messages", kind: "herald", realm: "personal", principal: @principal, config: config }.merge(attrs))
  end

  def config_errors(config)
    build(config: config).tap(&:valid?).errors[:config].to_sentence
  end

  test "it saves with a ULID id and hands out its adapter" do
    row = build
    assert row.save, row.errors.full_messages.to_sentence
    assert_match(/\A[0-9A-HJKMNP-TV-Z]{26}\z/, row.id)
    assert_instance_of Texts::Backends::Herald, row.adapter
    assert_equal "http://mini.test:8379", build(config: HERALD.merge("url" => "http://mini.test:8379/")).url
  end

  test "the kind must be a registered adapter, the owner a person, the realm a real one" do
    assert_match(/"sms" is not a text backend kind \(herald\)/, build(kind: "sms").tap(&:valid?).errors[:kind].to_sentence)
    muse, = agent("muse")
    refute build(principal: muse).valid?
    assert_match(/unknown realm/, build(realm: "secret").tap(&:valid?).errors[:realm].to_sentence)
    refute build(name: "Jenner Messages").valid?
  end

  test "config: a url and a key, and nothing it does not know" do
    assert_match(/needs a url/, config_errors(HERALD.except("url")))
    assert_match(/needs a key or a key_env/, config_errors(HERALD.except("key_env")))
    assert_match(/not both/, config_errors(HERALD.merge("key" => "k")))
    assert_match(/read_only is true or false/, config_errors(HERALD.merge("read_only" => "yes")))
    assert_match(/unknown keys mailboxes/, config_errors(HERALD.merge("mailboxes" => [])))
    assert build(config: HERALD.merge("addr" => "100.64.0.7", "read_only" => true)).valid?
  end

  test "a key_env is an environment variable's name, and a key put there is refused without being repeated" do
    message = config_errors(HERALD.merge("key_env" => "hrd_abcdef0123456789"))
    assert_match(/key_env names an environment variable/, message)
    refute_includes message, "hrd_abcdef0123456789"
  end

  test "the key never comes back out" do
    row = build(config: HERALD.except("key_env").merge("key" => "hrd_s3cr3t"))
    assert_equal "set", row.as_json.dig("config", "key")
    refute_includes row.as_json.to_json, "s3cr3t"
    refute_includes row.inspect, "s3cr3t"
  end
end
