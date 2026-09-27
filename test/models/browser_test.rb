require "test_helper"

# A browser is a row (BROWSE.md): whose logins, in which realm, reached how.
class BrowserTest < ActiveSupport::TestCase
  GOFER = { "url" => "http://mini.test:8378", "key_env" => "HOB_TEST_GOFER_KEY" }.freeze

  setup { ENV["HOB_TEST_GOFER_KEY"] = "gofer-secret" }
  teardown { ENV.delete("HOB_TEST_GOFER_KEY") }

  def build(**attrs)
    Browser.new({ name: "mini-chrome", kind: "gofer", realm: "personal", principal: @principal, config: GOFER }.merge(attrs))
  end

  test "a gofer browser saves with a ULID id, enabled, and answers with its adapter" do
    row = build
    assert row.save, row.errors.full_messages.to_sentence
    assert_match(/\A[0-9A-HJKMNP-TV-Z]{26}\z/, row.id)
    assert row.enabled?
    assert_instance_of Browse::Backends::Gofer, row.adapter
    assert_equal [], row.domains
  end

  test "the name is a unique slug; the kind is a registered adapter, the fake only under test" do
    build.save!
    refute build.valid?, "taken"
    refute build(name: "Mini Chrome").valid?
    row = build(kind: "chromedriver")
    refute row.valid?
    assert_match(/"chromedriver" is not a browser kind \(gofer, fake\)/, row.errors[:kind].to_sentence)
    assert build(name: "fake-one", kind: "fake", config: {}).valid?
    assert_equal %w[gofer], Browse::Backends::KINDS.keys, "production rows cannot name the fake"
  end

  test "the owner is a person and the realm is a real one" do
    muse, = agent("muse")
    refute build(principal: muse).valid?
    refute build(principal: nil).valid?
    refute build(realm: "secret").valid?
  end

  test "a gofer config needs a url, exactly one way to a key, and domains as a list" do
    assert_match(/needs a url/, build(config: { "key" => "k" }).tap(&:valid?).errors[:config].to_sentence)
    assert_match(/needs a key or a key_env/, build(config: { "url" => "http://mini.test" }).tap(&:valid?).errors[:config].to_sentence)
    assert_match(/not both/, build(config: GOFER.merge("key" => "k")).tap(&:valid?).errors[:config].to_sentence)
    assert_match(/unknown keys token/, build(config: GOFER.merge("token" => "x")).tap(&:valid?).errors[:config].to_sentence)
    assert_match(/domains must be an array/, build(config: GOFER.merge("domains" => "amazon.com")).tap(&:valid?).errors[:config].to_sentence)
    row = build(config: GOFER.merge("addr" => "100.64.0.7", "domains" => [ "amazon.com" ]))
    assert row.valid?, row.errors.full_messages.to_sentence
    assert_equal [ "amazon.com" ], row.domains
  end

  test "the key is read from the environment at request time, or from the row, and never shown" do
    row = build
    assert_equal "gofer-secret", row.key
    ENV["HOB_TEST_GOFER_KEY"] = "rotated"
    assert_equal "rotated", row.key
    ENV.delete("HOB_TEST_GOFER_KEY")
    assert_nil row.key
    assert_equal({ "url" => "http://mini.test:8378", "key_env" => "HOB_TEST_GOFER_KEY" }, row.as_json["config"])

    inline = build(name: "inline", config: { "url" => "http://mini.test", "key" => "in-the-row" })
    assert_equal "in-the-row", inline.key
    assert_equal "set", inline.as_json["config"]["key"]
    refute_includes inline.inspect, "in-the-row"
  end

  test "a browser is realm-scoped: a household request cannot see a personal one" do
    build.save!
    build(name: "house-chrome", realm: "household").save!
    assert_equal %w[house-chrome mini-chrome], Browser.order(:name).pluck(:name)
    clearance!("household")
    assert_equal %w[house-chrome], Browser.order(:name).pluck(:name)
    assert_nil Browser.find_by(name: "mini-chrome")
  end
end
