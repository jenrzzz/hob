require "test_helper"

# A todo backend is a row (TODOS.md): whose todos, in which realm, reached how.
class TodoBackendTest < ActiveSupport::TestCase
  TALLY = { "url" => "http://mini.test:8377", "key_env" => "HOB_TEST_TALLY_KEY" }.freeze

  setup { ENV["HOB_TEST_TALLY_KEY"] = "tally-secret" }
  teardown { ENV.delete("HOB_TEST_TALLY_KEY") }

  def build(**attrs)
    TodoBackend.new({ name: "jenner-omnifocus", kind: "omnifocus", realm: "personal", principal: @principal, config: TALLY }.merge(attrs))
  end

  test "an omnifocus backend saves with a ULID id, enabled and not primary" do
    row = build
    assert row.save, row.errors.full_messages.to_sentence
    assert_match(/\A[0-9A-HJKMNP-TV-Z]{26}\z/, row.id)
    assert row.enabled?
    refute row.primary?
    assert_instance_of Todos::Backends::Omnifocus, row.adapter
    assert_equal row, row.adapter.backend
  end

  test "the name is a unique slug, because it prefixes every todo id" do
    build.save!
    refute build.valid?, "taken"
    [ "Jenner OmniFocus", "jenner:of", "jenner/of", "-of", "" ].each do |name|
      refute build(name: name).valid?, "#{name.inspect} should not be a name"
    end
    [ "house", "jenner.of", "tessa_reminders-2" ].each { |name| assert build(name: name).valid?, name }
  end

  test "the kind must be a registered adapter; the fake is one only under test" do
    row = build(kind: "things")
    refute row.valid?
    assert_match(/"things" is not a todo backend kind \(omnifocus, fake\)/, row.errors[:kind].to_sentence)
    assert build(kind: "fake", config: {}).valid?
    assert_equal %w[omnifocus], Todos::Backends::KINDS.keys, "production rows cannot name the fake"
  end

  test "the owner is a person and the realm is a real one" do
    muse, = agent("muse")
    refute build(principal: muse).valid?
    refute build(principal: nil).valid?
    row = build(realm: "secret")
    refute row.valid?
    assert_match(/unknown realm/, row.errors[:realm].to_sentence)
  end

  test "an omnifocus config needs a url and exactly one way to a key" do
    assert_match(/needs a url/, build(config: { "key" => "k" }).tap(&:valid?).errors[:config].to_sentence)
    assert_match(/needs a url/, build(config: { "url" => "mini:8377", "key" => "k" }).tap(&:valid?).errors[:config].to_sentence)
    assert_match(/needs a key or a key_env/, build(config: { "url" => "http://mini.test" }).tap(&:valid?).errors[:config].to_sentence)
    both = build(config: TALLY.merge("key" => "k"))
    assert_match(/not both/, both.tap(&:valid?).errors[:config].to_sentence)
    assert_match(/unknown keys token/, build(config: TALLY.merge("token" => "x")).tap(&:valid?).errors[:config].to_sentence)
    assert build(config: TALLY.merge("addr" => "100.64.0.7", "create_tags" => true)).valid?
  end

  test "the key is read from the environment at request time, or from the row" do
    row = build
    assert_equal "tally-secret", row.key
    ENV["HOB_TEST_TALLY_KEY"] = "rotated"
    assert_equal "rotated", row.key
    ENV.delete("HOB_TEST_TALLY_KEY")
    assert_nil row.key

    assert_equal "inline", build(config: { "url" => "http://mini.test", "key" => "inline" }).key
    assert_equal "http://mini.test:8377", build(config: TALLY.merge("url" => "http://mini.test:8377/")).url
    assert_equal "100.64.0.7", build(config: TALLY.merge("addr" => "100.64.0.7")).addr
  end

  test "the key never leaves: as_json says it is set, inspect masks the config" do
    row = build(config: { "url" => "http://mini.test", "key" => "inline-secret" })
    row.save!
    json = row.as_json
    assert_equal({ "url" => "http://mini.test", "key" => "set" }, json["config"])
    assert_equal "tester", json["owner"]
    assert_equal %w[id name kind owner realm enabled primary config created_at updated_at], json.keys
    refute_includes row.to_json, "inline-secret"
    refute_includes row.inspect, "inline-secret"
    refute_includes [ row ].to_json, "inline-secret"

    env = build(name: "by-env").as_json
    assert_equal({ "url" => "http://mini.test:8377", "key_env" => "HOB_TEST_TALLY_KEY" }, env["config"])
    refute_includes env.to_json, "tally-secret"
  end

  test "one primary per owner: a new primary demotes the old one, and nobody else's" do
    tessa = Principal.create!(name: "tessa", kind: "human", max_clearance: "household")
    first = build(primary: true).tap(&:save!)
    hers = build(name: "tessa-reminders", principal: tessa, realm: "household", primary: true).tap(&:save!)
    second = build(name: "jenner-things", primary: true).tap(&:save!)

    refute first.reload.primary?
    assert second.reload.primary?
    assert hers.reload.primary?

    first.update!(primary: true)
    refute second.reload.primary?
  end

  test "realm visibility is RLS: a household clearance cannot see, or register, a personal backend" do
    build.save!
    build(name: "house", realm: "household").save!

    clearance!("household")
    assert_equal %w[house], TodoBackend.order(:name).pluck(:name)
    assert_nil TodoBackend.find_by(name: "jenner-omnifocus")
    assert_raises(ActiveRecord::StatementInvalid) { build(name: "sneaky").save! }
  ensure
    clearance!("intimate")
  end
end
