require_relative "test_helper"

class TodosClientTest < Minitest::Test
  TODO = { "id" => "jenner-omnifocus:kXv3", "backend" => "jenner-omnifocus", "title" => "Call the plumber", "notes" => "",
           "status" => "open", "actionable" => true, "blocked" => false, "flagged" => true, "due_at" => "2026-09-22T00:00:00Z",
           "tags" => [ "Phone" ], "list" => { "id" => "jenner-omnifocus:pQ7", "name" => "House" } }.freeze

  def setup
    @http = FakeHTTP.new
    @hob = Hob::Client.new(http: @http)
  end

  def test_list_sends_filters_and_reads_todos_and_unavailable_backends
    @http.respond("todos" => [ TODO ], "unavailable" => [ { "backend" => "house", "error" => "the mini is asleep" } ])
    todos = @hob.todos.list(actionable: true, tag: %w[Phone Home], due_before: Time.utc(2026, 10, 1), sort: "-due", backend: nil)
    assert_equal "/v1/todos", @http.requests.last.path
    assert_equal({ actionable: true, "tag[]" => %w[Phone Home], due_before: "2026-10-01T00:00:00Z", sort: "-due" }, @http.requests.last.query)

    assert_equal 1, todos.size
    assert_equal [ "Call the plumber" ], todos.map(&:title)
    todo = todos[0]
    assert todo.open?
    assert todo.actionable?
    assert todo.flagged?
    refute todo.done?
    assert_equal "House", todo.list["name"]
    assert todos.partial?
    assert_equal "house", todos.unavailable.first["backend"]

    @http.respond("todos" => [], "unavailable" => [])
    empty = @hob.todos.list(tag: "Phone")
    assert_equal({ tag: "Phone" }, @http.requests.last.query)
    assert empty.empty?
    refute empty.partial?
  end

  def test_find_create_update_and_the_actions
    @http.respond(TODO)
    assert_equal "Call the plumber", @hob.todos.find("jenner-omnifocus:kXv3").title
    assert_equal [ :get, "/v1/todos/jenner-omnifocus%3AkXv3" ], [ @http.requests.last.method, @http.requests.last.path ]

    @http.respond(TODO)
    @hob.todos.create(title: "Call the plumber", due_at: Time.utc(2026, 9, 22), tags: [ "Phone" ], list: "House")
    assert_equal [ :post, "/v1/todos" ], [ @http.requests.last.method, @http.requests.last.path ]
    assert_equal({ title: "Call the plumber", due_at: "2026-09-22T00:00:00Z", tags: [ "Phone" ], list: "House" }, @http.requests.last.body)

    @http.respond(TODO.merge("due_at" => nil))
    updated = @hob.todos.update("jenner-omnifocus:kXv3", due_at: nil, notes_append: "Tried twice")
    assert_equal :patch, @http.requests.last.method
    assert_equal({ due_at: nil, notes_append: "Tried twice" }, @http.requests.last.body, "nil is sent: it clears the date")
    assert_nil updated.due_at

    @http.respond(TODO.merge("status" => "done", "next" => TODO.merge("id" => "jenner-omnifocus:next1")))
    done = @hob.todos.complete(Hob::Todo.new(TODO))
    assert_equal [ :post, "/v1/todos/jenner-omnifocus%3AkXv3/complete", nil ], @http.requests.last.to_a.first(3)
    assert done.done?
    assert_equal "jenner-omnifocus:next1", done.next.id

    @http.respond(TODO)
    assert_nil @hob.todos.reopen("jenner-omnifocus:kXv3").next
    assert_equal "/v1/todos/jenner-omnifocus%3AkXv3/reopen", @http.requests.last.path
    @http.respond(TODO.merge("status" => "dropped"))
    assert @hob.todos.drop("jenner-omnifocus:kXv3").dropped?
    assert_equal "/v1/todos/jenner-omnifocus%3AkXv3/drop", @http.requests.last.path

    @http.respond({})
    assert_equal true, @hob.todos.delete("jenner-omnifocus:odd id")
    assert_equal [ :delete, "/v1/todos/jenner-omnifocus%3Aodd%20id" ], [ @http.requests.last.method, @http.requests.last.path ]
  end

  def test_lists_and_backends
    @http.respond("lists" => [ { "id" => "house:inbox", "backend" => "house", "name" => "Inbox", "kind" => "inbox", "open_count" => 4 },
                               { "id" => "house:pQ7", "backend" => "house", "name" => "Garden", "kind" => "project", "path" => "Home" } ],
                  "unavailable" => [])
    lists = @hob.todos.lists(backend: "house", status: "all")
    assert_equal "/v1/todo_lists", @http.requests.last.path
    assert_equal({ backend: "house", status: "all" }, @http.requests.last.query)
    assert lists[0].inbox?
    assert_equal [ "Home", 4 ], [ lists.last.path, lists[0].open_count ]

    @http.respond([ { "name" => "jenner-omnifocus", "kind" => "omnifocus", "realm" => "personal", "primary" => true,
                      "config" => { "url" => "http://mini:8377", "key_env" => "TALLY_KEY" } } ])
    backend = @hob.todos.backends.first
    assert_equal "/v1/todo_backends", @http.requests.last.path
    assert_equal [ "jenner-omnifocus", "personal", "TALLY_KEY" ], [ backend.name, backend.realm, backend.config["key_env"] ]
  end

  def test_errors_are_hobs
    @http.raise_with(Hob::NotFound.new("no todo backend named \"nope\""))
    assert_raises(Hob::NotFound) { @hob.todos.find("nope:1") }
    assert_instance_of Hob::Invalid, Hob::HTTP::Errors.for_response(422, { "error" => "unknown attribute priority" })
    assert_instance_of Hob::Invalid, Hob::HTTP::Errors.for_response(403, { "error" => "the todo backend refused hob's key" })
    assert_instance_of Hob::Unavailable, Hob::HTTP::Errors.for_response(503, { "error" => "OmniFocus did not answer", "status" => "unavailable" })
  end
end

class FakeTodosTest < Minitest::Test
  def setup
    @hob = Hob::Fake.new
  end

  def test_the_fake_keeps_todos_in_memory_with_the_clients_surface
    garden = @hob.todos.add_list("Garden", path: "Home")
    milk = @hob.todos.create(title: "Buy milk", tags: [ "Groceries" ], due_at: Time.utc(2026, 9, 25))
    roses = @hob.todos.create(title: "Prune roses", list: "Garden", flagged: true, due_at: "2026-09-21T00:00:00Z")
    assert_equal "fake", milk.backend
    assert_match(/\Afake:todo_/, milk.id)
    assert_equal "2026-09-25T00:00:00Z", milk.due_at
    assert_equal({ "id" => garden, "name" => "Garden" }, roses.list)

    assert_equal [ "Buy milk", "Prune roses" ], @hob.todos.list.map(&:title)
    assert_equal [ "Prune roses", "Buy milk" ], @hob.todos.list(sort: "due").map(&:title)
    assert_equal [ "Prune roses" ], @hob.todos.list(flagged: true).map(&:title)
    assert_equal [ "Buy milk" ], @hob.todos.list(tag: "Groceries", list: "fake:inbox").map(&:title)
    assert_equal [ "Prune roses" ], @hob.todos.list(q: "ROSES", list: garden).map(&:title)
    assert_equal [ "Prune roses" ], @hob.todos.list(due_before: Time.utc(2026, 9, 22)).map(&:title)
    refute @hob.todos.list.partial?

    updated = @hob.todos.update(milk, notes_append: "oat", add_tags: [ "Today" ], due_at: nil, list: garden)
    assert_equal [ "oat", %w[Groceries Today], nil, "Garden" ], [ updated.notes, updated.tags, updated.due_at, updated.list["name"] ]
    assert_equal [ [ "Inbox", 0 ], [ "Garden", 2 ] ], @hob.todos.lists.map { |l| [ l.name, l.open_count ] }

    assert @hob.todos.complete(milk).done?
    assert_equal [ "Prune roses" ], @hob.todos.list.map(&:title)
    assert_equal [ "Buy milk" ], @hob.todos.list(status: "done").map(&:title)
    assert @hob.todos.reopen(milk.id).open?
    assert @hob.todos.drop(milk.id).dropped?
    assert_equal 2, @hob.todos.list(status: "all").size

    child = @hob.todos.create(title: "Find the shears", parent_id: roses.id)
    assert_equal roses.id, child.parent_id
    assert @hob.todos.find(roses.id).has_children
    assert @hob.todos.delete(roses.id)
    assert_raises(Hob::NotFound) { @hob.todos.find(child.id) }
    assert_equal [ "fake" ], @hob.todos.backends.map(&:name)
  end

  def test_the_fake_refuses_what_the_server_would
    assert_raises(Hob::Invalid) { @hob.todos.create(notes: "untitled") }
    error = assert_raises(Hob::Invalid) { @hob.todos.create(title: "x", priority: 1) }
    assert_match(/unknown attribute priority/, error.message)
    assert_raises(Hob::Invalid) { @hob.todos.create(title: "x", notes_append: "create has no append") }
    assert_raises(Hob::Invalid) { @hob.todos.list(colour: "red") }
    assert_raises(Hob::NotFound) { @hob.todos.create(title: "x", backend: "elsewhere") }
    assert_raises(Hob::NotFound) { @hob.todos.create(title: "x", list: "No Such Project") }
    todo = @hob.todos.create(title: "x")
    assert_raises(Hob::Invalid) { @hob.todos.update(todo) }
    assert_raises(Hob::NotFound) { @hob.todos.complete("fake:nope") }
  end
end
