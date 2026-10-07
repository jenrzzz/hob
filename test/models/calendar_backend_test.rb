require "test_helper"

# A calendar backend is a row (CALENDARS.md): whose calendars, in which
# realm, reached how; and the secrets in it stay in it.
class CalendarBackendTest < ActiveSupport::TestCase
  FASTMAIL = { "username" => "jenner@fastmail.test", "key_env" => "HOB_TEST_CALDAV_KEY" }.freeze
  FEED = { "url" => "https://calendar.google.test/calendar/ical/abc/private-s3cr3t/basic.ics" }.freeze

  def build(kind: "fastmail", config: FASTMAIL, **attrs)
    CalendarBackend.new({ name: "jenner-fastmail", kind: kind, realm: "personal", principal: @principal, config: config }.merge(attrs))
  end

  def config_errors(config, kind: "fastmail")
    build(kind: kind, config: config).tap(&:valid?).errors[:config].to_sentence
  end

  test "each kind saves with a ULID id and hands out its adapter" do
    { "fastmail" => FASTMAIL, "ics" => FEED, "caldav" => FASTMAIL.merge("url" => "https://dav.example.test/cal/") }.each do |kind, config|
      row = build(kind: kind, config: config, name: "a-#{kind}")
      assert row.save, row.errors.full_messages.to_sentence
      assert_match(/\A[0-9A-HJKMNP-TV-Z]{26}\z/, row.id)
      assert_equal "Calendars::Backends::#{kind.capitalize}", row.adapter.class.name
    end
  end

  test "the kind must be a registered adapter, the owner a person, the realm a real one" do
    assert_match(/"google" is not a calendar backend kind \(ics, fastmail, caldav\)/, build(kind: "google").tap(&:valid?).errors[:kind].to_sentence)
    muse, = agent("muse")
    refute build(principal: muse).valid?
    assert_match(/unknown realm/, build(realm: "secret").tap(&:valid?).errors[:realm].to_sentence)
    refute build(name: "Jenner Fastmail").valid?
  end

  test "config: what each kind needs, and nothing it does not know" do
    assert_match(/needs a username/, config_errors(FASTMAIL.except("username")))
    assert_match(/needs a key or a key_env/, config_errors(FASTMAIL.except("key_env")))
    assert_match(/not both/, config_errors(FASTMAIL.merge("key" => "k")))
    assert_match(/calendars is a list/, config_errors(FASTMAIL.merge("calendars" => "Family")))
    assert_match(/needs a url/, config_errors(FASTMAIL, kind: "caldav"))
    assert_match(/needs a url or a url_env/, config_errors({}, kind: "ics"))
    assert_match(/http, https, or webcal/, config_errors({ "url" => "file:///etc/passwd" }, kind: "ics"))
    assert_match(/unknown keys username/, config_errors(FEED.merge("username" => "x"), kind: "ics"))
    assert_match(/time_zone is not a time zone/, config_errors(FASTMAIL.merge("time_zone" => "Mars/Olympus")))
    assert_match(/visibility is details or free_busy/, config_errors(FASTMAIL.merge("visibility" => "titles")))
    assert build(config: FASTMAIL.merge("calendars" => [ "Family" ], "visibility" => "free_busy", "time_zone" => "America/Los_Angeles")).valid?
    assert build(kind: "ics", config: { "url" => "webcal://example.test/x.ics" }).valid?
  end

  test "a *_env is an environment variable's name, and a secret put there is refused without being repeated" do
    message = config_errors(FASTMAIL.merge("key_env" => "abcd efgh ijkl"))
    assert_match(/key_env names an environment variable/, message)
    refute_includes message, "abcd efgh ijkl"
    assert_match(/url_env names an environment variable/, config_errors({ "url_env" => FEED["url"] }, kind: "ics"))
  end

  test "secrets never come back out: no key, and a feed URL is its host alone" do
    shown = build(config: FASTMAIL.except("key_env").merge("key" => "app-password")).as_json
    assert_equal "set", shown.dig("config", "key")
    feed = build(kind: "ics", config: FEED).as_json
    assert_equal "https://calendar.google.test/…", feed.dig("config", "url")
    refute_includes feed.to_json, "s3cr3t"
    refute_includes build(kind: "ics", config: FEED).inspect, "s3cr3t"
  end
end
