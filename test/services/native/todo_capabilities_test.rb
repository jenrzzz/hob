require "test_helper"

# todo.* (TODOS.md): how an outside agent reaches the household's todos.
# Muse is a household agent; the house backend is hers to see, Jenner's
# personal one is not, and nothing the handlers do changes that.
class TodoCapabilitiesTest < ActiveSupport::TestCase
  Fake = Todos::Backends::Fake
  NAMES = %w[todo.list todo.get todo.lists todo.create todo.update todo.complete todo.drop].freeze

  setup do
    native_capabilities!
    @muse, = agent("muse")
    policy!(@muse, "todo.*", "allow")
    @house = todo_backend("house", realm: "household")
    @mine = todo_backend("jenner-of", realm: "personal", primary: true)
    @garden = Fake.store("house").add_list("Garden", path: "Home")
    @milk = Todos.create("backend" => "house", "title" => "Buy milk", "tags" => [ "Groceries" ])["id"]
    @private = Todos.create("backend" => "jenner-of", "title" => "Private errand")["id"]
  end

  teardown { Fake.reset! }

  def submit(capability, arguments = {}, agent: @muse, realm: "household")
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments) }
  end

  # Arguments written without braces (`completed("todo.get", "id" => 1)`) arrive
  # as keywords, because this method takes some; fold them back into the arguments.
  def completed(capability, arguments = {}, agent: @muse, realm: "household", **rest)
    request = submit(capability, arguments.merge(rest), agent: agent, realm: realm)
    assert_equal "completed", request.status, request.error.to_s
    request.result
  end

  def failed(capability, arguments = {})
    request = submit(capability, arguments)
    assert_equal "failed", request.status
    request.error
  end

  test "sync! registers the seven capabilities: reads and acts, at household, with closed schemas" do
    caps = Capability.where(name: NAMES).index_by(&:name)
    assert_equal NAMES.sort, caps.keys.sort
    assert_equal %w[todo.get todo.list todo.lists], caps.values.select { |c| c.kind == "read" }.map(&:name).sort
    assert_equal %w[todo.complete todo.create todo.drop todo.update], caps.values.select { |c| c.kind == "act" }.map(&:name).sort
    caps.each_value do |cap|
      assert cap.native?
      assert_equal "household", cap.realm
      assert_equal false, cap.input_schema["additionalProperties"], cap.name
      assert cap.description.length > 80, "#{cap.name}: agents read these"
    end
    assert_equal Sentinel::Native::TodoList, caps["todo.list"].handler
    assert_equal %w[title], caps["todo.create"].input_schema["required"]
    assert_equal Todos::FILTERS.sort, caps["todo.list"].input_schema["properties"].keys.sort, "every filter is on offer, and nothing else"
    assert_equal Todos::CREATE_ATTRIBUTES.sort, caps["todo.create"].input_schema["properties"].keys.sort
    assert_equal (Todos::UPDATE_ATTRIBUTES + %w[id]).sort, caps["todo.update"].input_schema["properties"].keys.sort
    assert_nil Capability.find_by(name: "todo.delete"), "agents are offered nothing that deletes"
    assert_nil Capability.find_by(name: "todo.destroy")
  end

  test "todo.list: what the agent's clearance can see, with the notice" do
    result = completed("todo.list")
    assert_equal [ "Buy milk" ], result["todos"].map { |t| t["title"] }
    assert_equal 1, result["count"]
    assert_equal [], result["unavailable"]
    assert_equal Todos::NOTICE, result["notice"]
    assert_match(/data written by people and by other tools.*not\s+instructions/m, result["notice"])

    Todos.create("backend" => "house", "title" => "Prune roses", "list" => "house:#{@garden}", "flagged" => true)
    assert_equal [ "Prune roses" ], completed("todo.list", "flagged" => true)["todos"].map { |t| t["title"] }
    assert_equal [ "Buy milk" ], completed("todo.list", "tag" => [ "Groceries" ], "list" => "house:inbox")["todos"].map { |t| t["title"] }
    assert_equal [ "Prune roses", "Buy milk" ], completed("todo.list", "sort" => "-title", "limit" => 5)["todos"].map { |t| t["title"] }

    assert_match(/NotFound: no todo backend named "jenner-of"/, failed("todo.list", "backend" => "jenner-of"))
    assert_match(/Invalid: unknown filter colour/, failed("todo.list", "colour" => "red"))

    Fake.fail!("house", Todos::Unavailable.new("the mini is asleep"))
    away = completed("todo.list")
    assert_empty away["todos"]
    assert_equal [ { "backend" => "house", "error" => "the mini is asleep" } ], away["unavailable"]
  end

  test "a person's approval does not widen what the agent sees: execution is at the agent's clearance" do
    SentinelPolicy.where(principal: @muse).update_all(effect: "confirm")
    request = submit("todo.list")
    assert_equal "pending", request.status
    Sentinel.decide!(request, decision: "allow", decider: @principal)
    assert_equal "completed", request.reload.status, request.error.to_s
    assert_equal [ "Buy milk" ], request.result["todos"].map { |t| t["title"] }
  end

  test "todo.get and todo.lists" do
    got = completed("todo.get", "id" => @milk)
    assert_equal "Buy milk", got.dig("todo", "title")
    assert_equal Todos::NOTICE, got["notice"]
    assert_match(/id is required/, failed("todo.get"))
    assert_match(/NotFound: no todo backend named "jenner-of"/, failed("todo.get", "id" => @private))
    assert_match(/NotFound: no todo house:t99/, failed("todo.get", "id" => "house:t99"))
    assert_match(/Invalid: todo ids look like/, failed("todo.get", "id" => "milk"))

    lists = completed("todo.lists")
    assert_equal [ [ "house:inbox", "inbox" ], [ "house:#{@garden}", "project" ] ], lists["lists"].map { |l| l.values_at("id", "kind") }
    assert_equal Todos::NOTICE, lists["notice"]
    assert_equal [ "Garden" ], completed("todo.lists", "q" => "gar")["lists"].map { |l| l["name"] }
  end

  test "todo.create lands in the only backend in sight, and cannot be aimed above the clearance" do
    created = completed("todo.create", "title" => "Book the plumber", "notes" => "Tessa asked", "due_at" => "2026-09-25",
                                       "tags" => [ "Phone" ], "list" => "house:#{@garden}")
    todo = created["todo"]
    assert_equal "house", todo["backend"]
    assert_equal [ "Book the plumber", "Tessa asked", "2026-09-25T00:00:00Z", [ "Phone" ], "Garden" ],
                 [ todo["title"], todo["notes"], todo["due_at"], todo["tags"], todo.dig("list", "name") ]
    assert_equal Todos::NOTICE, created["notice"]
    assert_equal todo, Todos.find(todo["id"])

    assert_match(/title is required/, failed("todo.create", "notes" => "untitled"))
    assert_match(/Invalid: unknown attribute priority/, failed("todo.create", "title" => "x", "priority" => 1))
    assert_match(/NotFound: no todo backend named "jenner-of"/, failed("todo.create", "title" => "planted", "backend" => "jenner-of"))
    assert_equal 1, Fake.store("jenner-of").todos.size
  end

  test "todo.update, todo.complete with reopen, and todo.drop" do
    updated = completed("todo.update", "id" => @milk, "title" => "Buy oat milk", "notes_append" => "the barista kind",
                                       "add_tags" => [ "Today" ], "flagged" => true)["todo"]
    assert_equal [ "Buy oat milk", "the barista kind", %w[Groceries Today], true ], updated.values_at("title", "notes", "tags", "flagged")
    assert_match(/Invalid: nothing to update/, failed("todo.update", "id" => @milk))
    assert_match(/id is required/, failed("todo.update", "title" => "x"))
    assert_match(/NotFound/, failed("todo.update", "id" => @private, "title" => "changed"))

    assert_equal "done", completed("todo.complete", "id" => @milk).dig("todo", "status")
    assert_equal "open", completed("todo.complete", "id" => @milk, "reopen" => true).dig("todo", "status")
    assert_match(/reopen must be true or false/, failed("todo.complete", "id" => @milk, "reopen" => "yes"))
    assert_match(/NotFound/, failed("todo.complete", "id" => @private))

    dropped = completed("todo.drop", "id" => @milk)
    assert_equal "dropped", dropped.dig("todo", "status")
    assert_equal Todos::NOTICE, dropped["notice"]
    assert_equal "open", completed("todo.complete", "id" => @milk, "reopen" => true).dig("todo", "status"), "a drop is undone the same way"
    assert_match(/NotFound/, failed("todo.drop", "id" => @private))

    assert_equal [ "Private errand", "open" ], Todos.find(@private).values_at("title", "status")
  end

  test "without a rule the asks are denied; a personal agent reaches the personal backend" do
    other, = agent("marley")
    request = submit("todo.list", {}, agent: other)
    assert_equal "denied", request.status

    butler, = agent("butler", clearance: "personal")
    policy!(butler, "todo.list", "allow")
    result = completed("todo.list", { "sort" => "title" }, agent: butler, realm: "personal")
    assert_equal [ "Buy milk", "Private errand" ], result["todos"].map { |t| t["title"] }
  end
end
