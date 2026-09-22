require "test_helper"

# A budget backend is a row (BUDGET.md): whose budget, in which realm, reached how.
class BudgetBackendTest < ActiveSupport::TestCase
  YNAB = { "plan" => "11111111-2222-3333-4444-555555555555", "key_env" => "HOB_TEST_YNAB_TOKEN" }.freeze

  setup { ENV["HOB_TEST_YNAB_TOKEN"] = "ynab-secret" }
  teardown { ENV.delete("HOB_TEST_YNAB_TOKEN") }

  def build(**attrs)
    BudgetBackend.new({ name: "house-ynab", kind: "ynab", realm: "household", principal: @principal, config: YNAB }.merge(attrs))
  end

  def config_errors(config)
    build(config: config).tap(&:valid?).errors[:config].to_sentence
  end

  test "a ynab backend saves with a ULID id, enabled, and hands out its adapter" do
    row = build
    assert row.save, row.errors.full_messages.to_sentence
    assert_match(/\A[0-9A-HJKMNP-TV-Z]{26}\z/, row.id)
    assert row.enabled?
    assert_instance_of Budgets::Backends::Ynab, row.adapter
    assert_equal row, row.adapter.backend
  end

  test "the name is a unique slug, because it prefixes every id" do
    build.save!
    refute build.valid?, "taken"
    [ "House YNAB", "house:ynab", "house/ynab", "-ynab", "" ].each { |name| refute build(name: name).valid?, "#{name.inspect} should not be a name" }
  end

  test "the kind must be a registered adapter, the owner a person, the realm a real one" do
    assert_match(/"mint" is not a budget backend kind \(ynab\)/, build(kind: "mint").tap(&:valid?).errors[:kind].to_sentence)
    muse, = agent("muse")
    refute build(principal: muse).valid?
    refute build(principal: nil).valid?
    assert_match(/unknown realm/, build(realm: "secret").tap(&:valid?).errors[:realm].to_sentence)
  end

  test "a ynab config needs a plan and exactly one way to a token" do
    assert_match(/needs a plan/, config_errors(YNAB.except("plan")))
    assert_match(/needs a plan/, config_errors(YNAB.merge("plan" => "plans/../user")))
    assert_match(/needs a key or a key_env/, config_errors(YNAB.except("key_env")))
    assert_match(/not both/, config_errors(YNAB.merge("key" => "k")))
    assert_match(/unknown keys url/, config_errors(YNAB.merge("url" => "http://elsewhere.test")))
    assert_match(/time_zone is not a time zone/, config_errors(YNAB.merge("time_zone" => "Mars/Olympus")))
    assert build(config: YNAB.merge("plan" => "last-used", "time_zone" => "America/Los_Angeles")).valid?
  end

  test "a key_env is an environment variable's name, and a token put there is refused without being repeated" do
    message = config_errors(YNAB.merge("key_env" => "aB3-secret-token"))
    assert_match(/key_env names an environment variable/, message)
    refute_includes message, "aB3-secret-token"
  end

  test "the token is resolved at request time and never shown" do
    row = build
    assert_equal "ynab-secret", row.key
    ENV.delete("HOB_TEST_YNAB_TOKEN")
    assert_nil row.key

    stored = build(config: YNAB.except("key_env").merge("key" => "stored-token"))
    assert_equal "stored-token", stored.key
    assert_equal "set", stored.as_json.dig("config", "key")
    refute_includes stored.as_json.to_json, "stored-token"
    refute_includes stored.inspect, "stored-token"
    assert_equal "HOB_TEST_YNAB_TOKEN", row.as_json.dig("config", "key_env")
  end

  test "today is the owner's, not the server's" do
    travel_to Time.utc(2026, 9, 22, 3, 0) do
      assert_equal Date.new(2026, 9, 22), build.time_zone.today
      assert_equal Date.new(2026, 9, 21), build(config: YNAB.merge("time_zone" => "America/Los_Angeles")).time_zone.today
    end
  end

  test "a backend above the request's clearance is not there" do
    build(name: "jenner-ynab", realm: "personal").save!
    build.save!
    clearance!("household")
    assert_equal %w[house-ynab], BudgetBackend.pluck(:name)
  end
end
