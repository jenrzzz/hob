require "test_helper"
require_relative "../../support/fake_quire"

# note.* (NOTES.md): how an outside agent reaches the household's notes.
# Muse is a household agent; the household's row (a quire key scoped to the
# household folder) is hers to see, Jenner's personal one is not, and
# nothing the handlers do changes that. Notes stay inside the household, so
# writing one is an act a policy may allow without a person.
class NoteCapabilitiesTest < ActiveSupport::TestCase
  READS = %w[note.folders note.search note.get].freeze
  ACTS = %w[note.create note.append note.update].freeze

  setup do
    ENV["HOB_TEST_QUIRE_KEY"] = FakeQuire::KEY
    native_capabilities!
    @muse, = agent("muse")
    policy!(@muse, "note.*", "allow")
    Notes::Backends::Quire.transport = (@quire = FakeQuire.new).to_proc
    @house = @quire.folder("Household")
    @groceries = @quire.note(@house, "Groceries", text: "oranges", modified: "2026-11-13T17:01:00Z")
    note_backend("house-notes", realm: "household")
    note_backend("jenner-notes")
  end

  teardown do
    Notes::Backends::Quire.transport = nil
    ENV.delete("HOB_TEST_QUIRE_KEY")
  end

  def submit(capability, arguments = {}, agent: @muse, realm: "household")
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments) }
  end

  def completed(capability, arguments = {})
    request = submit(capability, arguments)
    assert_equal "completed", request.status, request.error.to_s
    request.result
  end

  test "sync! registers three reads and three acts at household, with closed schemas, none of them waiting on a person" do
    caps = Capability.where("name LIKE 'note.%'").index_by(&:name)
    assert_equal (READS + ACTS).sort, caps.keys.sort
    caps.each_value do |cap|
      assert cap.native?
      assert_equal [ READS.include?(cap.name) ? "read" : "act", "household", false ],
                   [ cap.kind, cap.realm, cap.input_schema["additionalProperties"] ], cap.name
      assert cap.description.length > 80, "#{cap.name}: agents read these"
    end
    assert_empty caps.values.select(&:requires_person?)
    assert_equal Notes::FOLDER_FILTERS.sort, caps["note.folders"].input_schema["properties"].keys.sort
    assert_equal Notes::SEARCH_FILTERS.sort, caps["note.search"].input_schema["properties"].keys.sort
    assert_equal Notes::GET_ARGUMENTS.sort, caps["note.get"].input_schema["properties"].keys.sort
    assert_equal Notes::CREATE_ARGUMENTS.sort, caps["note.create"].input_schema["properties"].keys.sort
    assert_equal Notes::APPEND_ARGUMENTS.sort, caps["note.append"].input_schema["properties"].keys.sort
    assert_equal Notes::UPDATE_ARGUMENTS.sort, caps["note.update"].input_schema["properties"].keys.sort
  end

  test "the reads: the notes the agent's clearance can see, with the notice" do
    result = completed("note.search")
    assert_equal [ "house-notes:#{@groceries}" ], result["notes"].map { |n| n["id"] }
    assert_equal [ 1, [] ], result.values_at("count", "unavailable")
    assert_equal Notes::NOTICE, result["notice"]
    assert_match(/shared note.*not instructions/m, result["notice"])
    assert_equal [ "house-notes:#{@house}" ], completed("note.folders")["folders"].map { |f| f["id"] }
    assert_equal "Groceries\noranges", completed("note.get", { "id" => "house-notes:#{@groceries}" }).dig("note", "text")
  end

  test "a personal library does not exist for a household agent, whatever it names" do
    assert_match(/NotFound: no note backend named "jenner-notes"/, submit("note.get", { "id" => "jenner-notes:#{@groceries}" }).error)
    assert_match(/NotFound/, submit("note.folders", { "backend" => "jenner-notes" }).error)
    assert_match(/NotFound/, submit("note.append", { "id" => "jenner-notes:#{@groceries}", "text" => "x" }).error)
    assert_empty @quire.writes

    skipsy, = agent("skipsy", clearance: "personal")
    policy!(skipsy, "note.*", "allow")
    request = submit("note.get", { "id" => "jenner-notes:#{@groceries}" }, agent: skipsy, realm: "personal")
    assert_equal "completed", request.status, request.error.to_s
  end

  test "the writes go when a policy allows them, and only as far as it allows" do
    created = completed("note.create", { "folder" => "house-notes:#{@house}", "title" => "Pickup", "text" => "Ana at 5" })
    assert_equal "Pickup", created.dig("note", "title")
    assert_equal "Groceries\noranges\neggs", completed("note.append", { "id" => "house-notes:#{@groceries}", "text" => "eggs" }).dig("note", "text")
    assert_equal "Shopping", completed("note.update", { "id" => "house-notes:#{@groceries}", "title" => "Shopping" }).dig("note", "title")
    assert_equal 3, @quire.writes.size

    skipsy, = agent("skipsy")
    policy!(skipsy, "note.append", "allow")
    policy!(skipsy, "note.update", "deny")
    assert_equal "completed", submit("note.append", { "id" => "house-notes:#{@groceries}", "text" => "milk" }, agent: skipsy).status
    refute_equal "completed", submit("note.update", { "id" => "house-notes:#{@groceries}", "text" => "gone" }, agent: skipsy).status
    assert_equal 4, @quire.writes.size, "the denied rewrite never reached quire"
  end

  test "a person's assistant gets the same capabilities as MCP tools" do
    names = Mcp.tools("household").keys
    (READS + ACTS).each { |name| assert_includes names, name.tr(".", "_") }
    as(@principal, realm: "personal") { Mcp.call("note_append", { "id" => "jenner-notes:#{@groceries}", "text" => "From me." }) }
    assert_equal [ "PATCH", @groceries, { "append" => "From me." } ], @quire.writes.last
  end
end
