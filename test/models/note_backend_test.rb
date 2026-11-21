require "test_helper"

# A note backend is a row (NOTES.md): whose notes, in which realm, reached
# how; and the key in it stays in it.
class NoteBackendTest < ActiveSupport::TestCase
  QUIRE = { "url" => "http://mini.test:8380", "key_env" => "QUIRE_KEY" }.freeze

  def build(config: QUIRE, **attrs)
    NoteBackend.new({ name: "jenner-notes", kind: "quire", realm: "personal", principal: @principal, config: config }.merge(attrs))
  end

  def config_errors(config)
    build(config: config).tap(&:valid?).errors[:config].to_sentence
  end

  test "it saves with a ULID id and hands out its adapter" do
    row = build
    assert row.save, row.errors.full_messages.to_sentence
    assert_match(/\A[0-9A-HJKMNP-TV-Z]{26}\z/, row.id)
    assert_instance_of Notes::Backends::Quire, row.adapter
    assert_equal "http://mini.test:8380", build(config: QUIRE.merge("url" => "http://mini.test:8380/")).url
  end

  test "the kind must be a registered adapter, the owner a person, the realm a real one" do
    assert_match(/"obsidian" is not a note backend kind \(quire\)/, build(kind: "obsidian").tap(&:valid?).errors[:kind].to_sentence)
    muse, = agent("muse")
    refute build(principal: muse).valid?
    assert_match(/unknown realm/, build(realm: "secret").tap(&:valid?).errors[:realm].to_sentence)
    refute build(name: "Jenner Notes").valid?
  end

  test "a library kept for one agent names an agent, and says so" do
    meluzina, = agent("meluzina", clearance: "personal")
    row = build(name: "meluzina-notes", agent: meluzina)
    assert row.save, row.errors.full_messages.to_sentence
    assert_equal "meluzina", row.as_json["agent"]
    assert_match(/must be an agent: #{@principal.name} is a human/, build(agent: @principal).tap(&:valid?).errors[:agent].to_sentence)
    assert_nil build.as_json["agent"]
  end

  test "config: a url and a key, and nothing it does not know" do
    assert_match(/needs a url/, config_errors(QUIRE.except("url")))
    assert_match(/needs a key or a key_env/, config_errors(QUIRE.except("key_env")))
    assert_match(/not both/, config_errors(QUIRE.merge("key" => "k")))
    assert_match(/read_only is true or false/, config_errors(QUIRE.merge("read_only" => "yes")))
    assert_match(/unknown keys folders/, config_errors(QUIRE.merge("folders" => [])))
    assert build(config: QUIRE.merge("addr" => "100.64.0.7", "read_only" => true)).valid?
  end

  test "a key_env is an environment variable's name, and a key put there is refused without being repeated" do
    message = config_errors(QUIRE.merge("key_env" => "qre_abcdef0123456789"))
    assert_match(/key_env names an environment variable/, message)
    refute_includes message, "qre_abcdef0123456789"
  end

  test "the key never comes back out" do
    row = build(config: QUIRE.except("key_env").merge("key" => "qre_s3cr3t"))
    assert_equal "set", row.as_json.dig("config", "key")
    refute_includes row.as_json.to_json, "s3cr3t"
    refute_includes row.inspect, "s3cr3t"
  end

  test "a household request does not see a personal library" do
    note_backend("jenner-notes")
    note_backend("house-notes", realm: "household")
    muse, = agent("muse")
    assert_equal [ "house-notes" ], as(muse, realm: "household") { NoteBackend.pluck(:name) }
  end
end
