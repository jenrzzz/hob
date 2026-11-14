require "test_helper"
require_relative "../support/fake_quire"

# Notes (NOTES.md) over the quire adapter, with quire faked at the
# transport: what hob sends (the key, the paths, the ids encoded, the
# filters), what the façade merges and trims, how writes are put together,
# and what each failure becomes.
class NotesTest < ActiveSupport::TestCase
  setup do
    ENV["HOB_TEST_QUIRE_KEY"] = FakeQuire::KEY
    ENV["HOB_TIME_ZONE"] = "America/Los_Angeles"
    Notes::Backends::Quire.transport = (@quire = FakeQuire.new).to_proc
    @house = @quire.folder("Household")
    @recipes = @quire.folder("Recipes", parent: @house)
    @pancakes = @quire.note(@recipes, "Pancakes", text: "2 cups flour #breakfast", modified: "2026-11-10T16:00:00Z")
    @groceries = @quire.note(@house, "Groceries", text: "oranges\nmilk", modified: "2026-11-13T17:01:00Z")
    @diary = @quire.note(@house, "Diary", modified: "2026-11-01T08:00:00Z", locked: true)
  end

  teardown do
    Notes::Backends::Quire.transport = nil
    ENV.delete("HOB_TEST_QUIRE_KEY")
    ENV.delete("HOB_TIME_ZONE")
  end

  def id(native, backend = "jenner-notes") = "#{backend}:#{native}"

  test "folders: by path, ids and parents prefixed, the key sent as a bearer" do
    note_backend
    folders = Notes.folders["folders"]
    assert_equal [ "Household", "Household : Recipes" ], folders.map { |f| f["path"] }
    assert_equal({ "id" => id(@recipes), "backend" => "jenner-notes", "name" => "Recipes", "path" => "Household : Recipes",
                   "account" => "iCloud", "parent_id" => id(@house), "shared" => false, "note_count" => 1, "folder_count" => 0 }, folders.last)
    call = @quire.calls.last
    assert_equal [ "GET", "http://mini.test:8380/v1/folders", "Bearer qre_test" ], [ call.verb, call.url, call.headers["Authorization"] ]
    assert_equal [ "Household : Recipes" ], Notes.folders("q" => "recipes")["folders"].map { |f| f["path"] }
  end

  test "search: newest first, prefixed, times in the household's zone, text only when asked for" do
    note_backend
    result = Notes.search
    assert_equal [ "Groceries", "Pancakes", "Diary" ], result["notes"].map { |n| n["title"] }
    assert_equal({ "sort" => "-modified", "limit" => "50" }, @quire.calls.last.query)
    groceries = result["notes"].first
    assert_equal({ "id" => id(@groceries), "backend" => "jenner-notes", "title" => "Groceries",
                   "folder" => { "id" => id(@house), "name" => "Household", "path" => "Household" }, "account" => "iCloud",
                   "created" => "2026-11-13T09:01:00-08:00", "modified" => "2026-11-13T09:01:00-08:00", "locked" => false, "shared" => false }, groceries)
    refute result["truncated"]

    found = Notes.search("folder" => id(@house), "q" => "flour", "tag" => "#breakfast", "modified_after" => "2026-11-01", "modified_before" => "2026-11-14T00:00:00-08:00")
    assert_equal [ [ "Pancakes", "2 cups flour #breakfast", [ "breakfast" ] ] ], found["notes"].map { |n| n.values_at("title", "snippet", "tags") }
    assert_equal({ "folder" => [ @house ], "q" => [ "flour" ], "tag" => [ "breakfast" ], "modified_after" => [ "2026-11-01T07:00:00Z" ],
                   "modified_before" => [ "2026-11-14T08:00:00Z" ], "sort" => [ "-modified" ], "limit" => [ "50" ] }, @quire.calls.last.params,
                 "the folder goes without hob's prefix, a bare date is midnight where the household is, sent in UTC")
    Notes.search("tag" => %w[a b], "snippet" => true)
    assert_equal [ %w[a b], [ "snippet" ] ], @quire.calls.last.params.values_at("tag", "include")

    limited = Notes.search("limit" => 2)
    assert_equal [ 2, true ], [ limited["notes"].size, limited["truncated"] ]
  end

  test "get: one note in full, its id one encoded path segment" do
    note_backend
    note = Notes.get("id" => id(@groceries))["note"]
    assert_equal [ "Groceries\noranges\nmilk", %w[receipt.pdf] ], [ note["text"], note["attachments"].map { |a| a["name"] } ]
    assert_equal({ "name" => "receipt.pdf", "content_type" => "com.adobe.pdf" }, note["attachments"].first)
    assert_equal "/v1/notes/#{ERB::Util.url_encode(@groceries)}", @quire.calls.last.path
    refute_includes @quire.calls.last.path.delete_prefix("/v1/notes/"), "/"
    assert_nil Notes.get("id" => id(@diary))["note"]["text"], "a locked note has no text to give"
    refute Notes.get("id" => id(@groceries))["note"]["folder"].key?("deleted")

    @quire.respond(200, { "id" => @groceries, "title" => "Groceries", "locked" => false,
                          "folder" => { "id" => "x-coredata://S/ICFolder/p3", "name" => "Recently Deleted", "path" => "Recently Deleted", "deleted" => true } })
    assert_equal true, Notes.get("id" => id(@groceries))["note"].dig("folder", "deleted"), "one in Recently Deleted says so"
  end

  test "create, append, update: what goes to quire, and the note that comes back" do
    note_backend
    created = Notes.create("folder" => id(@recipes), "title" => "Waffles", "text" => "batter")["note"]
    assert_equal [ "Waffles", id(@recipes) ], [ created["title"], created.dig("folder", "id") ]
    assert_equal [ "POST", nil, { "folder" => @recipes, "title" => "Waffles", "text" => "batter" } ], @quire.writes.last
    assert_equal "application/json", @quire.calls.last.headers["Content-Type"]
    Notes.create("text" => "Loose thought")
    assert_equal({ "text" => "Loose thought" }, @quire.writes.last.last, "with no folder, quire's default")

    appended = Notes.append("id" => id(@groceries), "text" => "eggs")["note"]
    assert_equal "Groceries\noranges\nmilk\neggs", appended["text"]
    assert_equal [ "PATCH", @groceries, { "append" => "eggs" } ], @quire.writes.last

    moved = Notes.update("id" => id(@groceries), "title" => "Shopping", "folder" => id(@recipes))["note"]
    assert_equal [ "Shopping", id(@recipes) ], [ moved["title"], moved.dig("folder", "id") ]
    assert_equal({ "title" => "Shopping", "folder" => @recipes }, @quire.writes.last.last)
    Notes.update("id" => id(@groceries), "html" => "<div>x</div>")
    assert_equal({ "html" => "<div>x</div>" }, @quire.writes.last.last)
  end

  test "what goes in is checked before quire is asked" do
    note_backend
    note_backend("house-notes", realm: "household", read_only: true)
    assert_match(/unknown filter account/, assert_raises(Notes::Invalid) { Notes.search("account" => "iCloud") }.message)
    assert_match(/<backend>:<id>/, assert_raises(Notes::Invalid) { Notes.get("id" => "nocolon") }.message)
    assert_match(/with an offset/, assert_raises(Notes::Invalid) { Notes.search("modified_after" => "2026-11-06T10:00:00") }.message)
    assert_match(/not after/, assert_raises(Notes::Invalid) { Notes.search("modified_after" => "2026-11-06", "modified_before" => "2026-11-05") }.message)
    assert_match(/limit must be/, assert_raises(Notes::Invalid) { Notes.search("limit" => 0) }.message)
    assert_match(/hashtag's word/, assert_raises(Notes::Invalid) { Notes.search("tag" => "two words") }.message)
    assert_match(/different backends/, assert_raises(Notes::Invalid) { Notes.search("backend" => "x", "folder" => id(@house)) }.message)
    assert_match(/needs a title, text, or html/, assert_raises(Notes::Invalid) { Notes.create("folder" => id(@house)) }.message)
    assert_match(/not both/, assert_raises(Notes::Invalid) { Notes.create("folder" => id(@house), "title" => "x", "html" => "<div>y</div>") }.message)
    assert_match(/which library/, assert_raises(Notes::Invalid) { Notes.create("title" => "x") }.message)
    assert_match(/one line/, assert_raises(Notes::Invalid) { Notes.update("id" => id(@groceries), "title" => "a\nb") }.message)
    assert_match(/text is required/, assert_raises(Notes::Invalid) { Notes.append("id" => id(@groceries), "text" => " ") }.message)
    assert_match(/at most 100000/, assert_raises(Notes::Invalid) { Notes.append("id" => id(@groceries), "text" => "x" * 100_001) }.message)
    assert_match(/nothing to change/, assert_raises(Notes::Invalid) { Notes.update("id" => id(@groceries)) }.message)
    assert_match(/only within its own backend/, assert_raises(Notes::Invalid) { Notes.update("id" => id(@groceries), "folder" => id(@house, "house-notes")) }.message)
    assert_match(/read-only/, assert_raises(Notes::Invalid) { Notes.append("id" => id(@groceries, "house-notes"), "text" => "x") }.message)
    assert_raises(Notes::NotFound) { Notes.get("id" => id(@groceries, "nobody")) }
    assert_empty @quire.writes
    assert_raises(Notes::NotFound) { Notes.get("id" => id("#{FakeQuire::STORE}/ICNote/p999")) }
  end

  test "reads merge across libraries, and one that cannot answer is named, not fatal, unless it was asked for" do
    note_backend
    note_backend("house-notes", realm: "household")
    @quire.respond(503, { "error" => { "code" => "notes_unavailable", "message" => "Notes did not answer within 60s" } })
    result = Notes.search
    assert_equal [ { "backend" => "house-notes", "error" => "Notes did not answer within 60s" } ], result["unavailable"]
    assert_equal 3, result["notes"].size

    @quire.respond(503, { "error" => { "code" => "notes_unavailable", "message" => "no" } })
    assert_raises(Notes::Unavailable) { Notes.search("backend" => "house-notes") }
  end

  test "quire's errors become ours" do
    note_backend
    { 404 => Notes::NotFound, 400 => Notes::Invalid, 409 => Notes::Invalid, 413 => Notes::Invalid, 422 => Notes::Invalid,
      401 => Notes::Forbidden, 403 => Notes::Forbidden, 503 => Notes::Unavailable, 500 => Notes::Unavailable }.each do |status, error|
      @quire.respond(status, { "error" => { "code" => "x", "message" => "because" } })
      assert_raises(error, status.to_s) { Notes.folders("backend" => "jenner-notes") }
    end
    @quire.respond(409, { "error" => { "code" => "ambiguous", "message" => "two folders are called Recipes",
                                        "candidates" => [ { "id" => "a", "path" => "Household : Recipes" }, { "id" => "b", "path" => "Work : Recipes" } ] } })
    assert_match(/candidates: Household : Recipes; Work : Recipes/, assert_raises(Notes::Invalid) { Notes.folders("backend" => "jenner-notes") }.message)
    @quire.respond(422, { "error" => { "code" => "invalid", "message" => "the note is locked" } })
    assert_match(/locked/, assert_raises(Notes::Invalid) { Notes.append("id" => id(@diary), "text" => "x") }.message)
    Notes::Backends::Quire.transport = ->(*) { raise Errno::ECONNREFUSED }
    assert_match(/quire unreachable at mini.test/, assert_raises(Notes::Unavailable) { Notes.folders("backend" => "jenner-notes") }.message)
    ENV.delete("HOB_TEST_QUIRE_KEY")
    assert_match(/HOB_TEST_QUIRE_KEY is not set/, assert_raises(Notes::Unavailable) { Notes.folders("backend" => "jenner-notes") }.message)
  end

  test "check: quire's status, the key's scope included" do
    status = note_backend.adapter.check
    assert_equal [ true, "0.1.0", "hob", "4.13" ], [ status["reachable"], status["quire"], status.dig("quire_key", "name"), status.dig("notes_app", "version") ]
  end
end
