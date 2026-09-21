require "test_helper"

# /v1/todos and /v1/todo_lists over HTTP: the contract, the error mapping,
# and who can see what. Backends here are the in-memory Fake.
class TodosControllerTest < ActionDispatch::IntegrationTest
  Fake = Todos::Backends::Fake

  setup do
    @house = todo_backend("house", realm: "household")
    @mine = todo_backend("jenner.of", realm: "personal", primary: true)
    tessa = Principal.create!(name: "tessa", kind: "human", max_clearance: "household")
    @tessa_token = ApiKey.issue!(principal: tessa, surface: "phone", default_clearance: "household")
  end

  teardown { Fake.reset! }

  def tessa_auth
    { "Authorization" => "Bearer #{@tessa_token}" }
  end

  test "create, show, update, the member actions, and delete" do
    post "/v1/todos", params: { title: "Call the plumber", notes: "Leak under the sink", flagged: true, due_at: "2026-09-22", tags: [ "Phone" ] },
         headers: auth, as: :json
    assert_response :created
    assert_equal "jenner.of:t1", body["id"], "the caller's primary; ids carry colons and dots"
    assert_equal [ "Call the plumber", "open", true, [ "Phone" ] ], body.values_at("title", "status", "flagged", "tags")
    refute body.key?("todo"), "the body is the attributes, not a wrapped copy"

    get "/v1/todos/jenner.of:t1", headers: auth
    assert_response :ok
    assert_equal "Leak under the sink", body["notes"]

    patch "/v1/todos/jenner.of:t1", params: { notes_append: "Tried twice", due_at: nil, add_tags: [ "Waiting" ] }, headers: auth, as: :json
    assert_response :ok
    assert_equal "Leak under the sink\nTried twice", body["notes"]
    assert_nil body["due_at"]
    assert_equal %w[Phone Waiting], body["tags"]

    post "/v1/todos/jenner.of:t1/complete", headers: auth
    assert_response :ok
    assert_equal "done", body["status"]
    post "/v1/todos/jenner.of:t1/reopen", headers: auth
    assert_equal "open", body["status"]
    post "/v1/todos/jenner.of:t1/drop", headers: auth
    assert_equal "dropped", body["status"]

    delete "/v1/todos/jenner.of:t1", headers: auth
    assert_response :no_content
    get "/v1/todos/jenner.of:t1", headers: auth
    assert_response :not_found
    assert_match(/no todo jenner.of:t1/, body["error"])
  end

  test "index filters and merges; lists names where todos can go" do
    garden = Fake.store("house").add_list("Garden", path: "Home")
    Todos.create("backend" => "house", "title" => "Prune roses", "tags" => %w[Home Weekend], "list" => "house:#{garden}", "due_at" => "2026-10-05T00:00:00Z")
    Todos.create("backend" => "house", "title" => "Buy milk", "tags" => %w[Home])
    Todos.create("backend" => "jenner.of", "title" => "File taxes", "due_at" => "2026-09-21T00:00:00Z", "flagged" => true)

    get "/v1/todos", params: { sort: "due" }, headers: auth
    assert_response :ok
    assert_equal [ "File taxes", "Prune roses", "Buy milk" ], body["todos"].map { |t| t["title"] }
    assert_equal [], body["unavailable"]

    get "/v1/todos", params: { tag: %w[Home Weekend], backend: "house" }, headers: auth
    assert_equal [ "Prune roses" ], body["todos"].map { |t| t["title"] }
    get "/v1/todos?flagged=true&limit=5", headers: auth
    assert_equal [ "File taxes" ], body["todos"].map { |t| t["title"] }
    get "/v1/todos", params: { list: "house:inbox" }, headers: auth
    assert_equal [ "Buy milk" ], body["todos"].map { |t| t["title"] }

    get "/v1/todo_lists", params: { backend: "house" }, headers: auth
    assert_response :ok
    assert_equal [ [ "house:inbox", "inbox", 1 ], [ "house:#{garden}", "project", 1 ] ], body["lists"].map { |l| l.values_at("id", "kind", "open_count") }
    assert_equal "Home", body["lists"].last["path"]
    get "/v1/todo_lists", headers: auth
    assert_equal %w[house:inbox house:l1 jenner.of:inbox], body["lists"].map { |l| l["id"] }
  end

  test "errors map onto HTTP: 422 for the caller's mistakes, 404, 403 when the backend refuses hob, 503 when it is away" do
    post "/v1/todos", params: { title: "x", priority: "high" }, headers: auth, as: :json
    assert_response :unprocessable_entity
    assert_match(/unknown attribute priority/, body["error"])
    post "/v1/todos", params: { notes: "no title" }, headers: auth, as: :json
    assert_response :unprocessable_entity
    get "/v1/todos?colour=red", headers: auth
    assert_response :unprocessable_entity
    assert_match(/unknown filter colour/, body["error"])
    get "/v1/todo_lists?flagged=true", headers: auth
    assert_response :unprocessable_entity
    get "/v1/todos/not-an-id", headers: auth
    assert_response :unprocessable_entity
    patch "/v1/todos/house:t1", params: {}, headers: auth, as: :json
    assert_response :unprocessable_entity

    get "/v1/todos/nowhere:t1", headers: auth
    assert_response :not_found
    post "/v1/todos/house:t9/complete", headers: auth
    assert_response :not_found

    Fake.fail!("house", Todos::Unavailable.new("OmniFocus did not answer in 20s"))
    get "/v1/todos/house:t1", headers: auth
    assert_response :service_unavailable
    assert_equal({ "error" => "OmniFocus did not answer in 20s", "status" => "unavailable" }, body)
    get "/v1/todos", headers: auth
    assert_response :ok, "merged reads carry on without it"
    assert_equal [ { "backend" => "house", "error" => "OmniFocus did not answer in 20s" } ], body["unavailable"]
    get "/v1/todos?backend=house", headers: auth
    assert_response :service_unavailable

    Fake.fail!("house", Todos::Forbidden.new("tally refused house's key: unknown key"))
    post "/v1/todos", params: { title: "x", backend: "house" }, headers: auth, as: :json
    assert_response :forbidden
    assert_match(/the todo backend refused hob's key: tally refused house's key/, body["error"])

    Fake.fail!("house", Todos::Error.new("tally answered HTTP 418"))
    get "/v1/todos/house:t1", headers: auth
    assert_response :bad_gateway
  end

  test "a household clearance cannot see, list, or write to a personal backend" do
    Todos.create("backend" => "jenner.of", "title" => "Private errand")
    Todos.create("backend" => "house", "title" => "Buy milk")

    [ tessa_auth, auth("X-Hob-Clearance" => "household") ].each do |headers|
      get "/v1/todos", headers: headers
      assert_response :ok
      assert_equal [ "Buy milk" ], body["todos"].map { |t| t["title"] }
      get "/v1/todo_lists", headers: headers
      assert_equal %w[house:inbox], body["lists"].map { |l| l["id"] }

      get "/v1/todos/jenner.of:t1", headers: headers
      assert_response :not_found
      assert_match(/no todo backend named "jenner.of"/, body["error"])
      get "/v1/todos?backend=jenner.of", headers: headers
      assert_response :not_found
      post "/v1/todos", params: { title: "planted", backend: "jenner.of" }, headers: headers, as: :json
      assert_response :not_found
      patch "/v1/todos/jenner.of:t1", params: { title: "changed" }, headers: headers, as: :json
      assert_response :not_found
      post "/v1/todos/jenner.of:t1/complete", headers: headers
      assert_response :not_found
      delete "/v1/todos/jenner.of:t1", headers: headers
      assert_response :not_found
    end

    assert_equal [ "Private errand", "open" ], Todos.find("jenner.of:t1").values_at("title", "status")
    assert_equal 1, Fake.store("jenner.of").todos.size

    # With one backend in sight, that is where a create with no backend goes.
    post "/v1/todos", params: { title: "Buy eggs" }, headers: tessa_auth, as: :json
    assert_response :created
    assert_equal "house", body["backend"]
  end

  test "agent keys do not reach todos directly; they ask the sentinel" do
    _muse, token = agent("muse")
    headers = { "Authorization" => "Bearer #{token}" }
    get "/v1/todos", headers: headers
    assert_response :forbidden
    assert_match(/agents act through the sentinel/, body["error"])
    post "/v1/todos", params: { title: "x" }, headers: headers, as: :json
    assert_response :forbidden
    post "/v1/todos/house:t1/complete", headers: headers
    assert_response :forbidden
    get "/v1/todo_lists", headers: headers
    assert_response :forbidden
    get "/v1/todo_backends", headers: headers
    assert_response :forbidden
    assert_empty Fake.store("house").todos
  end

  test "a surface's key reads and writes todos at its clearance" do
    mise = Principal.create!(name: "mise", kind: "surface", max_clearance: "household")
    token = ApiKey.issue!(principal: mise, surface: "mise", default_clearance: "household")
    post "/v1/todos", params: { title: "Buy saffron", tags: [ "Groceries" ] }, headers: { "Authorization" => "Bearer #{token}" }, as: :json
    assert_response :created
    assert_equal "house:t1", body["id"]
  end
end
