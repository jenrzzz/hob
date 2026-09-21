require "test_helper"

# Todos, the façade (TODOS.md), over the in-memory Fake backend: which
# backends a call reaches, what it refuses, and how answers merge.
class TodosTest < ActiveSupport::TestCase
  Fake = Todos::Backends::Fake

  setup do
    @house = todo_backend("house", realm: "household")
    @mine = todo_backend("jenner-of", realm: "personal", primary: true)
  end

  teardown { Fake.reset! }

  def titles(result)
    result["todos"].map { |t| t["title"] }
  end

  test "a created todo comes back in the normalized shape, with its backend in its id" do
    todo = Todos.create("title" => "Call the plumber", "notes" => "Leak under the sink", "flagged" => true,
                        "due_at" => "2026-09-22T17:00:00Z", "estimate_minutes" => 15, "tags" => [ "Phone" ])
    assert_equal "jenner-of:t1", todo["id"], "no backend named: the caller's primary"
    assert_equal "jenner-of", todo["backend"]
    assert_equal %w[id backend title notes status actionable blocked flagged due_at start_at planned_at completed_at tags list
                    parent_id has_children estimate_minutes repeats url created_at updated_at], todo.keys
    assert_equal "open", todo["status"]
    assert todo["actionable"]
    refute todo["blocked"]
    assert todo["flagged"]
    assert_equal "2026-09-22T17:00:00Z", todo["due_at"]
    assert_nil todo["list"], "null is the inbox"
    assert_equal [ "Phone" ], todo["tags"]
    assert_equal todo, Todos.find("jenner-of:t1")
  end

  test "ids split on the first colon; a malformed or unknown one is refused" do
    assert_equal [ "house", "a:b:c" ], Todos.parse_id("house:a:b:c")
    [ "house", ":t1", "house:", "" ].each { |id| assert_raises(Todos::Invalid) { Todos.find(id) } }
    assert_raises(Todos::NotFound) { Todos.find("nowhere:t1") }
    error = assert_raises(Todos::NotFound) { Todos.find("house:t99") }
    assert_match(/no todo house:t99/, error.message)

    @house.update!(enabled: false)
    assert_raises(Todos::NotFound) { Todos.find("house:t1") }
  end

  test "where a create lands: the named backend, the list's or parent's, the primary, the only one" do
    garden = Fake.store("house").add_list("Garden", path: "Home")
    assert_equal "house:t1", Todos.create("title" => "a", "backend" => "house")["id"]
    in_list = Todos.create("title" => "b", "list" => "house:#{garden}")
    assert_equal({ "id" => "house:#{garden}", "name" => "Garden" }, in_list["list"])
    child = Todos.create("title" => "c", "parent_id" => in_list["id"])
    assert_equal in_list["id"], child["parent_id"]
    assert_equal "Garden", child.dig("list", "name"), "a child sits where its parent does"
    assert Todos.find(in_list["id"])["has_children"]

    assert_match(/different backends/, assert_raises(Todos::Invalid) { Todos.create("title" => "d", "backend" => "jenner-of", "list" => "house:#{garden}") }.message)
    assert_raises(Todos::NotFound) { Todos.create("title" => "d", "backend" => "nope") }

    # A plain project name is a name, colon or not; it goes to the default backend.
    Fake.store("jenner-of").add_list("Home : Garden")
    assert_equal "Home : Garden", Todos.create("title" => "e", "list" => "Home : Garden").dig("list", "name")
    assert_raises(Todos::NotFound) { Todos.create("title" => "f", "list" => "No Such Project") }

    # Somebody with no primary of their own: the only visible one, else they must say.
    tessa = Principal.create!(name: "tessa", kind: "human", max_clearance: "household")
    as(tessa, realm: "household") { assert_equal "house", Todos.create("title" => "milk")["backend"] }
    as(tessa, realm: "personal") do
      assert_match(/name a backend: one of house, jenner-of/, assert_raises(Todos::Invalid) { Todos.create("title" => "eggs") }.message)
    end
    TodoBackend.update_all(enabled: false)
    assert_match(/no todo backend is visible/, assert_raises(Todos::Invalid) { Todos.create("title" => "x") }.message)
  end

  test "unknown and malformed attributes are refused, never ignored" do
    assert_match(/unknown attribute priority \(known: title, notes/, assert_raises(Todos::Invalid) { Todos.create("title" => "x", "priority" => 1) }.message)
    assert_match(/unknown attributes notes_append, add_tags/,
                 assert_raises(Todos::Invalid) { Todos.create("title" => "x", "notes_append" => "y", "add_tags" => [ "z" ]) }.message)
    assert_match(/title is required/, assert_raises(Todos::Invalid) { Todos.create("notes" => "x") }.message)
    assert_match(/title is required/, assert_raises(Todos::Invalid) { Todos.create("title" => " ") }.message)
    assert_match(/due_at must be an ISO8601/, assert_raises(Todos::Invalid) { Todos.create("title" => "x", "due_at" => "tomorrow") }.message)
    assert_match(/flagged must be true or false/, assert_raises(Todos::Invalid) { Todos.create("title" => "x", "flagged" => "yes") }.message)
    assert_match(/estimate_minutes must be a whole number/, assert_raises(Todos::Invalid) { Todos.create("title" => "x", "estimate_minutes" => "soon") }.message)
    assert_match(/tags must be a string/, assert_raises(Todos::Invalid) { Todos.create("title" => "x", "tags" => [ 1 ]) }.message)
    assert_empty Fake.store("jenner-of").todos

    todo = Todos.create(title: "symbols are fine", due_at: "2026-09-22")
    assert_equal "2026-09-22T00:00:00Z", todo["due_at"]
    assert_match(/unknown attribute backend/, assert_raises(Todos::Invalid) { Todos.update(todo["id"], "backend" => "house") }.message)
    assert_match(/nothing to update/, assert_raises(Todos::Invalid) { Todos.update(todo["id"], {}) }.message)
    assert_match(/title cannot be blank/, assert_raises(Todos::Invalid) { Todos.update(todo["id"], "title" => "") }.message)
    assert_match(/parent_id cannot be cleared/, assert_raises(Todos::Invalid) { Todos.update(todo["id"], "parent_id" => nil) }.message)
    assert_match(/not both/, assert_raises(Todos::Invalid) { Todos.update(todo["id"], "list" => "jenner-of:inbox", "parent_id" => todo["id"]) }.message)
  end

  test "update touches what is named: notes append, tags adjust, null clears, list moves" do
    garden = Fake.store("jenner-of").add_list("Garden")
    id = Todos.create("title" => "Prune", "notes" => "the roses", "tags" => %w[Home Tools], "due_at" => "2026-10-01", "list" => "Garden")["id"]

    todo = Todos.update(id, "notes_append" => "and the hedge", "add_tags" => [ "Weekend" ], "remove_tags" => [ "Tools" ], "due_at" => nil)
    assert_equal "the roses\nand the hedge", todo["notes"]
    assert_equal %w[Home Weekend], todo["tags"]
    assert_nil todo["due_at"]
    assert_equal "Prune", todo["title"]
    assert_equal "jenner-of:#{garden}", todo.dig("list", "id")

    assert_nil Todos.update(id, "list" => nil)["list"], "null is the inbox"
    assert_equal "Garden", Todos.update(id, "list" => "jenner-of:#{garden}").dig("list", "name")
    assert_nil Todos.update(id, "list" => "jenner-of:inbox")["list"]
    assert_equal [ "Only" ], Todos.update(id, "tags" => [ "Only" ], "notes" => nil).then { |t| t["notes"].empty? && t["tags"] }
  end

  test "complete, reopen, drop, destroy" do
    id = Todos.create("title" => "Pay the water bill")["id"]
    done = Todos.complete(id)
    assert_equal "done", done["status"]
    assert done["completed_at"].present?
    refute done["actionable"]
    refute done["blocked"], "blocked is for open todos"

    assert_equal "open", Todos.reopen(id)["status"]
    assert_nil Todos.find(id)["completed_at"]
    assert_equal "dropped", Todos.drop(id)["status"]
    assert_equal "open", Todos.reopen(id)["status"]

    child = Todos.create("title" => "find the bill", "parent_id" => id)["id"]
    assert Todos.destroy(id)
    assert_raises(Todos::NotFound) { Todos.find(id) }
    assert_raises(Todos::NotFound) { Todos.find(child) }
  end

  test "list filters: status, actionable, list, tags, flag, dates, text, limit" do
    store = Fake.store("house")
    garden = store.add_list("Garden")
    Todos.create("backend" => "house", "title" => "Call the plumber", "notes" => "leak under the sink", "tags" => %w[Phone Home],
                 "flagged" => true, "due_at" => "2026-09-22T00:00:00Z")
    Todos.create("backend" => "house", "title" => "Prune roses", "tags" => %w[Home], "list" => "house:#{garden}", "due_at" => "2026-10-05T00:00:00Z")
    later = Todos.create("backend" => "house", "title" => "Order bulbs", "start_at" => 1.year.from_now.utc.iso8601, "list" => "house:#{garden}")
    done = Todos.create("backend" => "house", "title" => "Sweep the porch")
    Todos.complete(done["id"])
    Todos.drop(Todos.create("backend" => "house", "title" => "Repaint the shed")["id"])

    assert_equal [ "Call the plumber", "Prune roses", "Order bulbs" ], titles(Todos.list("backend" => "house"))
    assert_equal [ "Sweep the porch" ], titles(Todos.list("status" => "done"))
    assert_equal [ "Repaint the shed" ], titles(Todos.list("status" => "dropped"))
    assert_equal 5, Todos.list("status" => "all")["todos"].size
    assert_equal [ "Call the plumber", "Prune roses" ], titles(Todos.list("actionable" => true))
    assert_equal [ "Order bulbs" ], titles(Todos.list("actionable" => "false"))
    assert Todos.find(later["id"])["blocked"]
    assert_equal [ "Prune roses", "Order bulbs" ], titles(Todos.list("list" => "house:#{garden}"))
    assert_equal [ "Call the plumber" ], titles(Todos.list("list" => "house:inbox"))
    assert_equal [ "Call the plumber", "Prune roses" ], titles(Todos.list("tag" => "Home"))
    assert_equal [ "Call the plumber" ], titles(Todos.list("tag" => %w[Home Phone])), "every tag named"
    assert_equal [ "Call the plumber" ], titles(Todos.list("flagged" => "true"))
    assert_equal [ "Prune roses", "Order bulbs" ], titles(Todos.list("flagged" => false))
    assert_equal [ "Call the plumber" ], titles(Todos.list("due_before" => "2026-10-01"))
    assert_equal [ "Prune roses" ], titles(Todos.list("due_after" => "2026-10-01T00:00:00Z"))
    assert_equal [ "Order bulbs" ], titles(Todos.list("start_before" => 2.years.from_now.utc.iso8601))
    assert_equal [ "Call the plumber" ], titles(Todos.list("q" => "SINK leak"))
    assert_empty titles(Todos.list("updated_after" => 1.hour.from_now.utc.iso8601))
    assert_equal 3, Todos.list("updated_after" => 1.hour.ago.utc.iso8601)["todos"].size
    assert_equal [ "Call the plumber" ], titles(Todos.list("limit" => 1))
    assert_equal [ "Prune roses", "Order bulbs", "Call the plumber" ], titles(Todos.list("sort" => "-title"))
    assert_equal [ "Call the plumber", "Prune roses", "Order bulbs" ], titles(Todos.list("sort" => "due")), "nulls last"
    assert_equal [ "Prune roses", "Call the plumber", "Order bulbs" ], titles(Todos.list("sort" => "-due")), "nulls last, reversed or not"
  end

  test "bad filters are refused" do
    {
      { "colour" => "red" } => /unknown filter colour \(known: backend, status/,
      { "status" => "closed" } => /status must be one of open, done, dropped, all/,
      { "status" => "done", "actionable" => true } => /actionable only applies to open todos/,
      { "sort" => "priority" } => /sort must be one of due, start, created, updated, title/,
      { "flagged" => "maybe" } => /flagged must be true or false/,
      { "due_before" => "next week" } => /due_before must be an ISO8601/,
      { "list" => "Garden" } => /look like <backend>:<id>/,
      { "backend" => "house", "list" => "jenner-of:inbox" } => /name different backends/
    }.each do |filters, message|
      assert_match message, assert_raises(Todos::Invalid) { Todos.list(filters) }.message
    end
    assert_raises(Todos::NotFound) { Todos.list("backend" => "nowhere") }
    assert_equal 500, Todos.normalize_filters("limit" => 9000)["limit"]
    assert_equal 100, Todos.normalize_filters({})["limit"]
    assert_equal 100, Todos.normalize_filters("limit" => "lots")["limit"]
  end

  test "with no backend named every visible one answers, merged and sorted; one that cannot is named, not fatal" do
    Todos.create("backend" => "house", "title" => "Buy milk", "due_at" => "2026-09-25T00:00:00Z")
    Todos.create("backend" => "jenner-of", "title" => "File taxes", "due_at" => "2026-09-21T00:00:00Z")
    Todos.create("backend" => "jenner-of", "title" => "Zip the tent", "due_at" => "2026-09-30T00:00:00Z")

    merged = Todos.list("sort" => "due")
    assert_equal [ "File taxes", "Buy milk", "Zip the tent" ], titles(merged)
    assert_empty merged["unavailable"]
    assert_equal [ "File taxes", "Buy milk" ], titles(Todos.list("sort" => "due", "limit" => 2)), "the limit is on the merged answer"
    assert_equal [ "Buy milk", "File taxes", "Zip the tent" ], titles(Todos.list), "unsorted: backend by backend, by name"

    Fake.fail!("jenner-of", Todos::Unavailable.new("the mini is asleep"))
    partial = Todos.list("sort" => "due")
    assert_equal [ "Buy milk" ], titles(partial)
    assert_equal [ { "backend" => "jenner-of", "error" => "the mini is asleep" } ], partial["unavailable"]
    assert_equal [ "jenner-of" ], Todos.lists["unavailable"].map { |u| u["backend"] }

    # Asked for by name, it is the whole question: the call fails.
    assert_raises(Todos::Unavailable) { Todos.list("backend" => "jenner-of") }
    assert_raises(Todos::Unavailable) { Todos.list("list" => "jenner-of:inbox") }
    assert_raises(Todos::Unavailable) { Todos.find("jenner-of:t1") }

    Fake.fail!("jenner-of", Todos::Forbidden.new("tally refused jenner-of's key"))
    assert_equal [ "jenner-of" ], Todos.list["unavailable"].map { |u| u["backend"] }

    @mine.update!(enabled: false)
    assert_empty Todos.list["unavailable"], "a disabled backend is not asked"
  end

  test "lists: projects and the synthetic inbox, per backend" do
    store = Fake.store("house")
    garden = store.add_list("Garden", path: "Home")
    store.add_list("Old kitchen", status: "done")
    Todos.create("backend" => "house", "title" => "Prune", "list" => "house:#{garden}")
    Todos.create("backend" => "house", "title" => "Loose thought")

    lists = Todos.lists("backend" => "house")["lists"]
    assert_equal [ { "id" => "house:inbox", "backend" => "house", "name" => "Inbox", "kind" => "inbox", "path" => nil, "status" => "active", "open_count" => 1 },
                   { "id" => "house:#{garden}", "backend" => "house", "name" => "Garden", "kind" => "project", "path" => "Home", "status" => "active", "open_count" => 1 } ],
                 lists
    assert_equal [ "Old kitchen" ], Todos.lists("backend" => "house", "status" => "done")["lists"].map { |l| l["name"] }
    assert_equal [ "Garden" ], Todos.lists("q" => "gard")["lists"].map { |l| l["name"] }
    assert_equal %w[house:inbox jenner-of:inbox], Todos.lists("q" => "inbox")["lists"].map { |l| l["id"] }

    store.inbox = false # a scoped key: no inbox to show
    assert_equal [ "Garden" ], Todos.lists("backend" => "house")["lists"].map { |l| l["name"] }
    assert_match(/unknown filter flagged/, assert_raises(Todos::Invalid) { Todos.lists("flagged" => true) }.message)
  end

  test "realms: a backend above the clearance does not exist, to read or to write" do
    Todos.create("backend" => "jenner-of", "title" => "Private errand")
    Todos.create("backend" => "house", "title" => "Buy milk")
    muse, = agent("muse")

    as(muse, realm: "household") do
      assert_equal %w[house], Todos.backends.map(&:name)
      assert_equal [ "Buy milk" ], titles(Todos.list)
      assert_equal %w[house:inbox], Todos.lists["lists"].map { |l| l["id"] }
      assert_match(/no todo backend named "jenner-of"/, assert_raises(Todos::NotFound) { Todos.find("jenner-of:t1") }.message)
      assert_raises(Todos::NotFound) { Todos.list("backend" => "jenner-of") }
      assert_raises(Todos::NotFound) { Todos.create("backend" => "jenner-of", "title" => "planted") }
      assert_raises(Todos::NotFound) { Todos.complete("jenner-of:t1") }
      assert_raises(Todos::NotFound) { Todos.update("jenner-of:t1", "title" => "changed") }
      assert_equal "house", Todos.create("title" => "Buy eggs")["backend"], "the only one in sight"
    end

    assert_equal "Private errand", Todos.find("jenner-of:t1")["title"]
    assert_equal 1, Fake.store("jenner-of").todos.size
  end
end
