require "test_helper"

# A mail backend is a row (MAIL.md): whose mail, in which realm, reached
# how; and the token in it stays in it.
class MailBackendTest < ActiveSupport::TestCase
  FASTMAIL = { "key_env" => "HOB_TEST_JMAP_TOKEN" }.freeze

  def build(kind: "fastmail", config: FASTMAIL, **attrs)
    MailBackend.new({ name: "jenner-fastmail", kind: kind, realm: "personal", principal: @principal, config: config }.merge(attrs))
  end

  def config_errors(config, kind: "fastmail")
    build(kind: kind, config: config).tap(&:valid?).errors[:config].to_sentence
  end

  test "each kind saves with a ULID id and hands out its adapter" do
    { "fastmail" => FASTMAIL, "jmap" => FASTMAIL.merge("url" => "https://jmap.example.test/session") }.each do |kind, config|
      row = build(kind: kind, config: config, name: "a-#{kind}")
      assert row.save, row.errors.full_messages.to_sentence
      assert_match(/\A[0-9A-HJKMNP-TV-Z]{26}\z/, row.id)
      assert_equal "Email::Backends::#{kind.capitalize}", row.adapter.class.name
    end
  end

  test "the kind must be a registered adapter, the owner a person, the realm a real one" do
    assert_match(/"imap" is not a mail backend kind \(fastmail, jmap\)/, build(kind: "imap").tap(&:valid?).errors[:kind].to_sentence)
    muse, = agent("muse")
    refute build(principal: muse).valid?
    assert_match(/unknown realm/, build(realm: "secret").tap(&:valid?).errors[:realm].to_sentence)
    refute build(name: "Jenner Fastmail").valid?
  end

  test "config: what each kind needs, and nothing it does not know" do
    assert_match(/needs a key or a key_env/, config_errors({}))
    assert_match(/not both/, config_errors(FASTMAIL.merge("key" => "k")))
    assert_match(/needs a url \(https\)/, config_errors(FASTMAIL, kind: "jmap"))
    assert_match(/needs a url \(https\)/, config_errors(FASTMAIL.merge("url" => "http://jmap.example.test/session"), kind: "jmap"))
    assert_match(/mailboxes is a list/, config_errors(FASTMAIL.merge("mailboxes" => "Household")))
    assert_match(/read_only is true or false/, config_errors(FASTMAIL.merge("read_only" => "yes")))
    assert_match(/unknown keys username/, config_errors(FASTMAIL.merge("username" => "x")))
    assert build(config: FASTMAIL.merge("mailboxes" => [ "Household" ], "read_only" => true)).valid?
    assert build(config: FASTMAIL.merge("url" => "https://api.fastmail.com/jmap/session")).valid?
  end

  test "a key_env is an environment variable's name, and a token put there is refused without being repeated" do
    message = config_errors({ "key_env" => "fmu1-abcdef0123456789" })
    assert_match(/key_env names an environment variable/, message)
    refute_includes message, "fmu1-abcdef0123456789"
  end

  test "the token never comes back out" do
    row = build(config: { "key" => "fmu1-s3cr3t" })
    assert_equal "set", row.as_json.dig("config", "key")
    refute_includes row.as_json.to_json, "s3cr3t"
    refute_includes row.inspect, "s3cr3t"
  end
end
