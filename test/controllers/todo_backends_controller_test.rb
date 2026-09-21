require "test_helper"

# /v1/todo_backends: a person registers where todos live. The key goes in
# and never comes back out.
class TodoBackendsControllerTest < ActionDispatch::IntegrationTest
  Omnifocus = Todos::Backends::Omnifocus

  setup do
    ENV["HOB_TEST_TALLY_KEY"] = "tally-secret"
    @calls = []
    @responses = []
    Omnifocus.transport = lambda do |verb, url, _body, headers|
      @calls << [ verb, url, headers["Authorization"] ]
      @responses.shift || [ 200, { "omnifocus" => { "version" => "4.5" }, "counts" => { "inbox" => 4 }, "last_sync" => nil,
                                   "key" => { "name" => "hob", "permissions" => %w[read write], "scope" => nil },
                                   "now" => "2026-09-20T07:05:00Z" }.to_json ]
    end
  end

  teardown do
    Omnifocus.transport = nil
    Todos::Backends::Fake.reset!
    ENV.delete("HOB_TEST_TALLY_KEY")
  end

  test "a person registers, reads, updates, checks, and forgets a backend; the key is never shown" do
    post "/v1/todo_backends", params: { name: "jenner-omnifocus", kind: "omnifocus", realm: "personal", primary: true,
                                        config: { url: "http://mini.test:8377", key: "inline-secret", addr: "100.64.0.7" } },
         headers: auth, as: :json
    assert_response :created
    assert_equal [ "jenner-omnifocus", "omnifocus", "personal", "tester", true, true ],
                 body.values_at("name", "kind", "realm", "owner", "enabled", "primary")
    assert_equal({ "url" => "http://mini.test:8377", "addr" => "100.64.0.7", "key" => "set" }, body["config"])
    refute_includes response.body, "inline-secret"
    assert_equal "inline-secret", TodoBackend.find_by!(name: "jenner-omnifocus").key

    get "/v1/todo_backends", headers: auth
    assert_response :ok
    assert_equal %w[jenner-omnifocus], body.map { |b| b["name"] }
    refute_includes response.body, "inline-secret"
    get "/v1/todo_backends/jenner-omnifocus", headers: auth
    assert_equal "set", body.dig("config", "key")
    refute_includes response.body, "inline-secret"

    post "/v1/todo_backends/jenner-omnifocus/check", headers: auth
    assert_response :ok
    assert_equal [ "jenner-omnifocus", true, 4 ], [ body["backend"], body["reachable"], body.dig("counts", "inbox") ]
    assert_equal [ "GET", "http://mini.test:8377/v1/status", "Bearer inline-secret" ], @calls.last
    refute_includes response.body, "inline-secret"

    # Swapping the stored key for an env var is one call; the rest of the config stays.
    patch "/v1/todo_backends/jenner-omnifocus", params: { config: { key_env: "HOB_TEST_TALLY_KEY", addr: nil }, enabled: false }, headers: auth, as: :json
    assert_response :ok
    assert_equal({ "url" => "http://mini.test:8377", "key_env" => "HOB_TEST_TALLY_KEY" }, body["config"])
    assert_equal false, body["enabled"]
    assert_equal "tally-secret", TodoBackend.find_by!(name: "jenner-omnifocus").key
    refute_includes response.body, "tally-secret"

    @responses << [ 503, { "error" => { "code" => "omnifocus_unavailable", "message" => "OmniFocus is not running" } }.to_json ]
    post "/v1/todo_backends/jenner-omnifocus/check", headers: auth
    assert_response :ok, "unreachable is an answer"
    assert_equal({ "backend" => "jenner-omnifocus", "reachable" => false, "error" => "OmniFocus is not running" }, body)
    assert_equal "Bearer tally-secret", @calls.last.last

    delete "/v1/todo_backends/jenner-omnifocus", headers: auth
    assert_response :no_content
    get "/v1/todo_backends/jenner-omnifocus", headers: auth
    assert_response :not_found
  end

  test "bad rows are refused: kind, config, owner, a realm above the clearance" do
    post "/v1/todo_backends", params: { name: "x", kind: "things", config: { url: "http://t.test", key: "k" } }, headers: auth, as: :json
    assert_response :unprocessable_entity
    assert_match(/not a todo backend kind/, body["error"])

    post "/v1/todo_backends", params: { name: "x", kind: "omnifocus", config: { url: "http://t.test" } }, headers: auth, as: :json
    assert_response :unprocessable_entity
    assert_match(/needs a key or a key_env/, body["error"])

    muse, = agent("muse")
    post "/v1/todo_backends", params: { name: "x", kind: "omnifocus", owner: muse.name, config: { url: "http://t.test", key: "k" } }, headers: auth, as: :json
    assert_response :unprocessable_entity
    assert_match(/must be a person/, body["error"])
    post "/v1/todo_backends", params: { name: "x", kind: "omnifocus", owner: "nobody", config: { url: "http://t.test", key: "k" } }, headers: auth, as: :json
    assert_response :not_found

    post "/v1/todo_backends", params: { name: "x", kind: "omnifocus", realm: "personal", config: { url: "http://t.test", key: "k" } },
         headers: auth("X-Hob-Clearance" => "household"), as: :json
    assert_response :unprocessable_entity
    assert_match(/realm above clearance/, body["error"])
    assert_equal 0, TodoBackend.count

    tessa = Principal.create!(name: "tessa", kind: "human", max_clearance: "household")
    post "/v1/todo_backends", params: { name: "house", kind: "omnifocus", owner: "tessa", config: { url: "http://t.test", key_env: "HOB_TEST_TALLY_KEY" } },
         headers: auth("X-Hob-Clearance" => "household"), as: :json
    assert_response :created
    assert_equal [ "household", "tessa" ], body.values_at("realm", "owner"), "the realm defaults to the request's clearance"
    assert_equal tessa, TodoBackend.find_by!(name: "house").principal
  end

  test "backends are a person's to manage, and realm-scoped like everything else" do
    todo_backend("house", realm: "household")
    todo_backend("jenner-of", realm: "personal")

    mise = Principal.create!(name: "mise", kind: "surface", max_clearance: "household")
    surface = { "Authorization" => "Bearer #{ApiKey.issue!(principal: mise, surface: 'mise', default_clearance: 'household')}" }
    get "/v1/todo_backends", headers: surface
    assert_response :forbidden
    assert_match(/needs a person's key/, body["error"])
    post "/v1/todo_backends/house/check", headers: surface
    assert_response :forbidden

    get "/v1/todo_backends", headers: auth("X-Hob-Clearance" => "household")
    assert_equal %w[house], body.map { |b| b["name"] }
    get "/v1/todo_backends/jenner-of", headers: auth("X-Hob-Clearance" => "household")
    assert_response :not_found
    delete "/v1/todo_backends/jenner-of", headers: auth("X-Hob-Clearance" => "household")
    assert_response :not_found
    assert TodoBackend.exists?(name: "jenner-of")
    # The name is taken, by a row this clearance cannot see: the index says so, not a 500.
    post "/v1/todo_backends", params: { name: "jenner-of", kind: "fake" }, headers: auth("X-Hob-Clearance" => "household"), as: :json
    assert_response :unprocessable_entity
    assert_match(/already been taken/, body["error"])

    get "/v1/todo_backends", headers: auth
    assert_equal %w[house jenner-of], body.map { |b| b["name"] }
  end
end
