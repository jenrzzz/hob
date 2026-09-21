require "test_helper"

# The omnifocus adapter against tally's API.md, with the transport injected:
# what hob sends (paths, params, bodies, the bearer key), how a tally task
# becomes a todo, and what each of tally's errors becomes.
class TodosOmnifocusTest < ActiveSupport::TestCase
  Omnifocus = Todos::Backends::Omnifocus
  Call = Struct.new(:verb, :url, :body, :headers) do
    def uri = URI(url)
    def path = uri.path
    def query = URI.decode_www_form(uri.query.to_s)
    def json = body && JSON.parse(body)
  end

  # The task in tally's API.md, as JSON.
  TASK = {
    "id" => "kXv3mPq9LQe", "name" => "Call the plumber", "note" => "Leak under the sink", "status" => "available",
    "completed" => false, "dropped" => false, "flagged" => true, "effective_flagged" => true,
    "due" => "2026-09-22T00:00:00Z", "effective_due" => "2026-09-22T00:00:00Z",
    "defer" => nil, "effective_defer" => nil, "planned" => nil, "effective_planned" => nil,
    "completed_at" => nil, "dropped_at" => nil, "added" => "2026-09-01T16:20:11Z", "modified" => "2026-09-19T02:11:40Z",
    "estimated_minutes" => 15, "tags" => [ { "id" => "aB3", "name" => "Phone" } ],
    "project" => { "id" => "pQ7", "name" => "House" }, "parent" => nil, "in_inbox" => false,
    "has_children" => false, "children_count" => 0, "sequential" => false, "completed_by_children" => false,
    "repetition" => nil, "notifications" => [], "url" => "omnifocus:///task/kXv3mPq9LQe"
  }.freeze

  PROJECT = {
    "id" => "pQ7", "name" => "House", "note" => "", "status" => "active",
    "folder" => { "id" => "fD1", "name" => "Home", "path" => "Home" }, "type" => "parallel",
    "task_count" => 12, "remaining_count" => 5, "available_count" => 3, "url" => "omnifocus:///task/pQ7"
  }.freeze

  STATUS = {
    "omnifocus" => { "version" => "4.5", "build" => "v185" },
    "counts" => { "tasks" => 900, "remaining" => 120, "inbox" => 4, "projects" => 30, "tags" => 12, "folders" => 5 },
    "last_sync" => "2026-09-20T07:00:00Z", "key" => { "name" => "hob", "permissions" => %w[read write delete], "scope" => nil },
    "now" => "2026-09-20T07:05:00Z"
  }.freeze

  setup do
    ENV["HOB_TEST_TALLY_KEY"] = "tally-secret"
    @backend = todo_backend("jenner-omnifocus", kind: "omnifocus", realm: "personal",
                            config: { "url" => "http://mini.test:8377/", "key_env" => "HOB_TEST_TALLY_KEY" })
    @calls = []
    @responses = []
    Omnifocus.transport = lambda do |verb, url, body, headers|
      @calls << Call.new(verb, url, body, headers)
      @responses.shift || [ 200, TASK.to_json ]
    end
  end

  teardown do
    Omnifocus.transport = nil
    ENV.delete("HOB_TEST_TALLY_KEY")
  end

  def respond(status, data)
    @responses << [ status, data.is_a?(String) ? data : data.to_json ]
  end

  def tally_error(status, code, message, **extra)
    respond(status, "error" => { "code" => code, "message" => message }.merge(extra.stringify_keys))
  end

  test "a tally task becomes a todo" do
    todo = Todos.find("jenner-omnifocus:kXv3mPq9LQe")
    assert_equal({
      "id" => "jenner-omnifocus:kXv3mPq9LQe", "backend" => "jenner-omnifocus", "title" => "Call the plumber",
      "notes" => "Leak under the sink", "status" => "open", "actionable" => true, "blocked" => false, "flagged" => true,
      "due_at" => "2026-09-22T00:00:00Z", "start_at" => nil, "planned_at" => nil, "completed_at" => nil,
      "tags" => [ "Phone" ], "list" => { "id" => "jenner-omnifocus:pQ7", "name" => "House" }, "parent_id" => nil,
      "has_children" => false, "estimate_minutes" => 15, "repeats" => false, "url" => "omnifocus:///task/kXv3mPq9LQe",
      "created_at" => "2026-09-01T16:20:11Z", "updated_at" => "2026-09-19T02:11:40Z"
    }, todo)

    call = @calls.last
    assert_equal "GET", call.verb
    assert_equal "http://mini.test:8377/v1/tasks/kXv3mPq9LQe", call.url, "the url's trailing slash is not doubled"
    assert_nil call.body
    assert_equal "Bearer tally-secret", call.headers["Authorization"]
    assert_equal "application/json", call.headers["Accept"]
  end

  test "status, effective values, nesting, and repeats map through" do
    adapter = @backend.adapter
    map = ->(overrides) { adapter.send(:todo, TASK.merge(overrides)) }

    %w[available next due_soon overdue].each do |status|
      assert map.("status" => status)["actionable"], status
    end
    blocked = map.("status" => "blocked", "defer" => "2026-10-01T09:00:00-07:00", "effective_defer" => "2026-10-01T09:00:00-07:00")
    assert_equal [ "open", false, true ], blocked.values_at("status", "actionable", "blocked")
    assert_equal "2026-10-01T16:00:00Z", blocked["start_at"], "start_at is the defer date, in UTC"

    done = map.("status" => "completed", "completed" => true, "completed_at" => "2026-09-20T01:00:00Z")
    assert_equal [ "done", false, false, "2026-09-20T01:00:00Z" ], done.values_at("status", "actionable", "blocked", "completed_at")
    assert_equal [ "dropped", false, false ], map.("status" => "dropped", "dropped" => true).values_at("status", "actionable", "blocked")

    inherited = map.("flagged" => false, "effective_flagged" => true, "due" => nil, "effective_due" => "2026-09-30T00:00:00Z",
                     "planned" => nil, "effective_planned" => "2026-09-25T00:00:00Z")
    assert inherited["flagged"], "effective: inherited from the project"
    assert_equal "2026-09-30T00:00:00Z", inherited["due_at"]
    assert_equal "2026-09-25T00:00:00Z", inherited["planned_at"]

    nested = map.("project" => nil, "in_inbox" => true, "parent" => { "id" => "par1", "name" => "Fix the sink" }, "has_children" => true,
                  "repetition" => { "rule" => "FREQ=WEEKLY", "method" => "fixed" }, "tags" => [], "note" => nil, "estimated_minutes" => nil)
    assert_nil nested["list"], "null is the inbox"
    assert_equal "jenner-omnifocus:par1", nested["parent_id"]
    assert nested["has_children"]
    assert nested["repeats"]
    assert_equal "", nested["notes"]
    assert_empty nested["tags"]
  end

  test "list sends tally's filters" do
    respond(200, "tasks" => [ TASK, TASK.merge("id" => "second", "name" => "Second") ], "total" => 2, "limit" => 100, "offset" => 0)
    result = Todos.list("backend" => "jenner-omnifocus")
    assert_equal [ "jenner-omnifocus:kXv3mPq9LQe", "jenner-omnifocus:second" ], result["todos"].map { |t| t["id"] }
    assert_equal "/v1/tasks", @calls.last.path
    assert_equal [ %w[status remaining], %w[limit 100] ], @calls.last.query

    respond(200, "tasks" => [])
    Todos.list("backend" => "jenner-omnifocus", "actionable" => true, "list" => "jenner-omnifocus:pQ7", "tag" => %w[Phone Home],
               "flagged" => true, "due_before" => "2026-10-01", "due_after" => "2026-09-01T00:00:00Z", "start_before" => "2026-09-21",
               "q" => "plumber sink", "updated_after" => "2026-09-19T00:00:00Z", "sort" => "-start", "limit" => 25)
    assert_equal [ %w[status available], %w[limit 25], %w[project pQ7], %w[tag Phone], %w[tag Home], %w[tag_mode all], %w[flagged true],
                   %w[due_before 2026-10-01], %w[due_after 2026-09-01T00:00:00Z], %w[defer_before 2026-09-21],
                   %w[modified_after 2026-09-19T00:00:00Z], [ "q", "plumber sink" ], %w[sort -defer] ], @calls.last.query

    {
      { "status" => "done" } => %w[status completed], { "status" => "dropped" } => %w[status dropped], { "status" => "all" } => %w[status all],
      { "actionable" => false } => %w[status blocked], { "list" => "jenner-omnifocus:inbox" } => %w[inbox true],
      { "tag" => "Phone" } => %w[tag Phone], { "flagged" => false } => %w[flagged false],
      { "sort" => "due" } => %w[sort due], { "sort" => "created" } => %w[sort added], { "sort" => "-updated" } => %w[sort -modified],
      { "sort" => "title" } => %w[sort name]
    }.each do |filters, pair|
      respond(200, "tasks" => [])
      Todos.list(filters)
      assert_includes @calls.last.query, pair, filters.inspect
      refute_includes @calls.last.query.map(&:first), "tag_mode"
    end
  end

  test "create sends tally's fields; where it goes is a project id, a project name, a parent, or nothing" do
    respond(201, TASK)
    todo = Todos.create("title" => "Call the plumber", "notes" => "Leak under the sink", "flagged" => true, "due_at" => "2026-09-22",
                        "start_at" => "2026-09-21T09:00:00Z", "planned_at" => "2026-09-21", "estimate_minutes" => 15,
                        "tags" => [ "Phone" ], "list" => "jenner-omnifocus:pQ7")
    assert_equal "jenner-omnifocus:kXv3mPq9LQe", todo["id"]
    assert_equal [ "POST", "/v1/tasks" ], [ @calls.last.verb, @calls.last.path ]
    assert_equal "application/json", @calls.last.headers["Content-Type"]
    assert_equal({ "name" => "Call the plumber", "note" => "Leak under the sink", "flagged" => true, "due" => "2026-09-22",
                   "defer" => "2026-09-21T09:00:00Z", "planned" => "2026-09-21", "estimated_minutes" => 15, "tags" => [ "Phone" ],
                   "project" => "pQ7" }, @calls.last.json)

    Todos.create("title" => "By name", "list" => "Home : House")
    assert_equal({ "name" => "By name", "project" => "Home : House" }, @calls.last.json)

    Todos.create("title" => "Nested", "parent_id" => "jenner-omnifocus:par1")
    assert_equal({ "name" => "Nested", "parent" => "par1" }, @calls.last.json)

    Todos.create("title" => "Inbox")
    assert_equal({ "name" => "Inbox" }, @calls.last.json)
    Todos.create("title" => "Inbox, said aloud", "list" => "jenner-omnifocus:inbox")
    assert_equal({ "name" => "Inbox, said aloud" }, @calls.last.json, "neither project nor parent is tally's inbox")

    assert_match(/not both/, assert_raises(Todos::Invalid) { Todos.create("title" => "x", "list" => "House", "parent_id" => "jenner-omnifocus:par1") }.message)

    @backend.update!(config: @backend.config.merge("create_tags" => true))
    Todos.create("title" => "New tag", "tags" => [ "Errands" ])
    assert_equal({ "name" => "New tag", "tags" => [ "Errands" ], "create_tags" => true }, @calls.last.json)
  end

  test "update patches only what was named; null clears; a null list is the inbox" do
    Todos.update("jenner-omnifocus:kXv3mPq9LQe", "title" => "Call a plumber", "notes_append" => "Tried twice", "due_at" => nil,
                 "add_tags" => [ "Waiting" ], "remove_tags" => [ "Phone" ], "estimate_minutes" => nil)
    assert_equal [ "PATCH", "/v1/tasks/kXv3mPq9LQe" ], [ @calls.last.verb, @calls.last.path ]
    assert_equal({ "name" => "Call a plumber", "note_append" => "Tried twice", "due" => nil, "add_tags" => [ "Waiting" ],
                   "remove_tags" => [ "Phone" ], "estimated_minutes" => nil }, @calls.last.json)

    Todos.update("jenner-omnifocus:kXv3mPq9LQe", "list" => nil)
    assert_equal({ "inbox" => true }, @calls.last.json)
    Todos.update("jenner-omnifocus:kXv3mPq9LQe", "list" => "jenner-omnifocus:inbox")
    assert_equal({ "inbox" => true }, @calls.last.json)
    Todos.update("jenner-omnifocus:kXv3mPq9LQe", "list" => "jenner-omnifocus:pQ9", "tags" => [])
    assert_equal({ "tags" => [], "project" => "pQ9" }, @calls.last.json)
    Todos.update("jenner-omnifocus:kXv3mPq9LQe", "parent_id" => "jenner-omnifocus:par1", "notes" => nil)
    assert_equal({ "note" => "", "parent" => "par1" }, @calls.last.json)
    assert_match(/parent_id "house:t1" is not in jenner-omnifocus/,
                 assert_raises(Todos::Invalid) { Todos.update("jenner-omnifocus:kXv3mPq9LQe", "parent_id" => "house:t1") }.message)
  end

  test "complete, reopen, drop, and destroy are tally's task actions" do
    respond(200, TASK.merge("status" => "completed", "completed" => true, "completed_at" => "2026-09-20T01:00:00Z",
                            "next" => TASK.merge("id" => "nextOne", "due" => "2026-09-29T00:00:00Z", "effective_due" => "2026-09-29T00:00:00Z")))
    done = Todos.complete("jenner-omnifocus:kXv3mPq9LQe")
    assert_equal [ "POST", "/v1/tasks/kXv3mPq9LQe/complete", {} ], [ @calls.last.verb, @calls.last.path, @calls.last.json ]
    assert_equal "done", done["status"]
    assert_equal "jenner-omnifocus:nextOne", done.dig("next", "id"), "a repeating task's next occurrence rides along"
    assert_equal "2026-09-29T00:00:00Z", done.dig("next", "due_at")

    refute Todos.complete("jenner-omnifocus:kXv3mPq9LQe").key?("next")

    Todos.reopen("jenner-omnifocus:kXv3mPq9LQe")
    assert_equal [ "POST", "/v1/tasks/kXv3mPq9LQe/reopen" ], [ @calls.last.verb, @calls.last.path ]
    Todos.drop("jenner-omnifocus:kXv3mPq9LQe")
    assert_equal [ "POST", "/v1/tasks/kXv3mPq9LQe/drop" ], [ @calls.last.verb, @calls.last.path ]

    respond(200, "deleted" => "kXv3mPq9LQe")
    assert_equal true, Todos.destroy("jenner-omnifocus:kXv3mPq9LQe")
    assert_equal [ "DELETE", "/v1/tasks/kXv3mPq9LQe", nil ], [ @calls.last.verb, @calls.last.path, @calls.last.body ]

    Todos.find("jenner-omnifocus:odd id/with?marks")
    assert_equal "http://mini.test:8377/v1/tasks/odd%20id%2Fwith%3Fmarks", @calls.last.url
  end

  test "lists are tally's projects, with the inbox in front unless the key is scoped" do
    respond(200, "projects" => [ PROJECT, PROJECT.merge("id" => "top", "name" => "Someday", "folder" => nil, "status" => "on_hold", "remaining_count" => 0) ])
    respond(200, STATUS)
    lists = Todos.lists("backend" => "jenner-omnifocus", "status" => "all")["lists"]
    assert_equal [
      { "id" => "jenner-omnifocus:inbox", "backend" => "jenner-omnifocus", "name" => "Inbox", "kind" => "inbox", "path" => nil, "status" => "active", "open_count" => 4 },
      { "id" => "jenner-omnifocus:pQ7", "backend" => "jenner-omnifocus", "name" => "House", "kind" => "project", "path" => "Home", "status" => "active", "open_count" => 5 },
      { "id" => "jenner-omnifocus:top", "backend" => "jenner-omnifocus", "name" => "Someday", "kind" => "project", "path" => nil, "status" => "on_hold", "open_count" => 0 }
    ], lists
    projects, status = @calls.last(2)
    assert_equal "/v1/projects", projects.path
    assert_equal [ %w[status all], %w[fields id,name,status,folder,remaining_count], %w[limit 2000] ], projects.query
    assert_equal "/v1/status", status.path

    # A scoped key (API.md, "Scoped keys") has no inbox: tally says so in its status, or refuses.
    respond(200, "projects" => [ PROJECT ])
    respond(200, STATUS.merge("key" => { "name" => "hob-household", "permissions" => %w[read write], "scope" => { "folders" => [ "Home" ] } }))
    assert_equal [ "House" ], Todos.lists["lists"].map { |l| l["name"] }
    assert_includes @calls[-2].query, %w[status active]

    respond(200, "projects" => [ PROJECT ])
    tally_error(403, "forbidden", "outside this key's scope")
    assert_equal [ "House" ], Todos.lists["lists"].map { |l| l["name"] }

    # Statuses without an inbox in them, or a q that is not it, ask tally nothing about it.
    respond(200, "projects" => [])
    assert_empty Todos.lists("status" => "done")["lists"]
    respond(200, "projects" => [ PROJECT ])
    assert_equal [ "House" ], Todos.lists("q" => "hou")["lists"].map { |l| l["name"] }
    assert_includes @calls.last.query, %w[q hou]
    assert_equal "/v1/projects", @calls.last.path
  end

  test "tally's errors become Todos errors" do
    tally_error(404, "not_found", "no task with id \"abc\"")
    assert_equal "no task with id \"abc\"", assert_raises(Todos::NotFound) { Todos.find("jenner-omnifocus:abc") }.message

    # What was missing decides whose mistake it was: the todo asked for is
    # a 404, a tag or project named in the request makes the request invalid.
    tally_error(404, "not_found", "no task with id \"abc\"", kind: "task")
    assert_raises(Todos::NotFound) { Todos.update("jenner-omnifocus:abc", "title" => "x") }
    tally_error(404, "not_found", "no tag with id or name \"Phone\"", kind: "tag")
    assert_equal "no tag with id or name \"Phone\"", assert_raises(Todos::Invalid) { Todos.update("jenner-omnifocus:abc", "tags" => [ "Phone" ]) }.message
    tally_error(404, "not_found", "no task with id \"gone\"", kind: "task")
    assert_raises(Todos::Invalid) { Todos.create("title" => "x", "parent_id" => "jenner-omnifocus:gone") }

    tally_error(400, "bad_request", "bad date \"soon\"")
    assert_equal "bad date \"soon\"", assert_raises(Todos::Invalid) { Todos.update("jenner-omnifocus:abc", "title" => "x") }.message

    tally_error(409, "ambiguous", "\"House\" matches 2 projects", candidates: [ { "id" => "pQ7", "name" => "House", "path" => "Home : House" },
                                                                                 { "id" => "pZ1", "name" => "House", "path" => "Work : House" } ])
    error = assert_raises(Todos::Invalid) { Todos.create("title" => "x", "list" => "House") }
    assert_equal "\"House\" matches 2 projects (candidates: Home : House pQ7; Work : House pZ1)", error.message

    tally_error(422, "invalid", "OmniFocus refused: a project cannot be its own parent")
    assert_match(/OmniFocus refused/, assert_raises(Todos::Invalid) { Todos.update("jenner-omnifocus:abc", "list" => "X") }.message)

    tally_error(401, "unauthorized", "unknown key")
    assert_equal "tally refused jenner-omnifocus's key: unknown key", assert_raises(Todos::Forbidden) { Todos.find("jenner-omnifocus:abc") }.message
    tally_error(403, "forbidden", "this key lacks the delete permission")
    assert_match(/lacks the delete permission/, assert_raises(Todos::Forbidden) { Todos.destroy("jenner-omnifocus:abc") }.message)

    tally_error(503, "omnifocus_unavailable", "OmniFocus did not answer in 20s")
    assert_equal "OmniFocus did not answer in 20s", assert_raises(Todos::Unavailable) { Todos.find("jenner-omnifocus:abc") }.message
    respond(502, "<html>Bad Gateway</html>")
    assert_match(/tally failed with HTTP 502/, assert_raises(Todos::Unavailable) { Todos.find("jenner-omnifocus:abc") }.message)
    respond(418, "")
    assert_match(/HTTP 418/, assert_raises(Todos::Error) { Todos.find("jenner-omnifocus:abc") }.message)
  end

  test "an unreachable tally, a timeout, or a missing key is Unavailable, and the key is not in the message" do
    [ Errno::ECONNREFUSED.new, Errno::EHOSTUNREACH.new, SocketError.new("getaddrinfo: nodename nor servname provided"),
      Net::OpenTimeout.new("execution expired"), Net::ReadTimeout.new, EOFError.new("end of file reached") ].each do |failure|
      Omnifocus.transport = ->(*) { raise failure }
      error = assert_raises(Todos::Unavailable, failure.class.name) { Todos.find("jenner-omnifocus:abc") }
      assert_match(/tally unreachable at mini\.test/, error.message)
      refute_includes error.message, "tally-secret"
    end

    # In a merged read it is a line in `unavailable`, not a failure.
    assert_match(/tally unreachable/, Todos.list["unavailable"].first["error"])

    Omnifocus.transport = ->(*) { flunk "nothing is sent without a key" }
    ENV.delete("HOB_TEST_TALLY_KEY")
    error = assert_raises(Todos::Unavailable) { Todos.find("jenner-omnifocus:abc") }
    assert_match(/HOB_TEST_TALLY_KEY is not set/, error.message)
  end

  test "the connection: short timeouts, and addr pins the address while the url keeps the name" do
    plain = @backend.adapter.send(:connection, URI("http://mini.test:8377/v1/status"))
    assert_equal [ "mini.test", 8377, false, 5, 30 ], [ plain.address, plain.port, plain.use_ssl?, plain.open_timeout, plain.read_timeout ]
    assert_nil plain.ipaddr

    @backend.update!(config: @backend.config.merge("url" => "https://tally.example.test", "addr" => "100.64.0.7"))
    pinned = @backend.adapter.send(:connection, URI("https://tally.example.test/v1/status"))
    assert_equal [ "tally.example.test", 443, true, "100.64.0.7" ], [ pinned.address, pinned.port, pinned.use_ssl?, pinned.ipaddr ]
  end

  test "check reads tally's status" do
    respond(200, STATUS)
    check = @backend.adapter.check
    assert_equal "/v1/status", @calls.last.path
    assert_equal true, check["reachable"]
    assert_equal "4.5", check.dig("omnifocus", "version")
    assert_equal 4, check.dig("counts", "inbox")
    assert_equal({ "name" => "hob", "permissions" => %w[read write delete], "scope" => nil }, check["tally_key"])

    tally_error(503, "omnifocus_unavailable", "OmniFocus is not running")
    assert_raises(Todos::Unavailable) { @backend.adapter.check }
  end
end
