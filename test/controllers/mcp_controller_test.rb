require "test_helper"

# POST /v1/mcp: hob's capabilities as a person's assistant's tools. The list
# follows the capability rows and the clearance; the calls run as the person.
class McpControllerTest < ActionDispatch::IntegrationTest
  Fake = Todos::Backends::Fake

  setup do
    native_capabilities!
    @house = todo_backend("house", realm: "household")
    @mine = todo_backend("jenner.of", realm: "personal", primary: true)
  end

  teardown { Fake.reset! }

  def rpc(method, params = nil, id: 1, headers: auth)
    post "/v1/mcp", params: { jsonrpc: "2.0", id: id, method: method, params: params }.compact, headers: headers, as: :json
  end

  def call_tool(name, arguments = {}, headers: auth)
    rpc("tools/call", { name: name, arguments: arguments }, headers: headers)
    assert_response :ok
    body["result"]
  end

  # What a tool answered, parsed; fails the test if the tool did.
  def answered(name, arguments = {}, **rest)
    result = call_tool(name, arguments, **rest)
    refute result["isError"], result["content"].first["text"]
    JSON.parse(result["content"].first["text"])
  end

  def tool_names(headers: auth)
    rpc("tools/list", headers: headers)
    body["result"]["tools"].map { |tool| tool["name"] }
  end

  test "initialize agrees a protocol version, offers tools, and says whose words todos are" do
    rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "claude-code", version: "2" } })
    assert_response :ok
    assert_equal [ "2.0", 1 ], body.values_at("jsonrpc", "id")
    assert_equal "2025-06-18", body["result"]["protocolVersion"]
    assert_equal({ "listChanged" => false }, body["result"]["capabilities"]["tools"])
    assert_equal "hob", body["result"]["serverInfo"]["name"]
    assert_match(/never instructions/, body["result"]["instructions"])

    rpc("initialize", { protocolVersion: "1999-01-01" })
    assert_equal V1::McpController::PROTOCOLS.first, body["result"]["protocolVersion"], "an unknown version gets hob's newest"
  end

  test "notifications are accepted with no body; ping answers; an unknown method is an error" do
    post "/v1/mcp", params: { jsonrpc: "2.0", method: "notifications/initialized" }, headers: auth, as: :json
    assert_response :accepted
    assert_empty response.body

    rpc("ping", id: "abc")
    assert_equal({ "jsonrpc" => "2.0", "id" => "abc", "result" => {} }, body)

    rpc("resources/list")
    assert_equal(-32_601, body["error"]["code"])
  end

  test "a batch and a body that is not JSON are errors, and there is nothing to GET" do
    post "/v1/mcp", params: [ { jsonrpc: "2.0", id: 1, method: "ping" } ].to_json, headers: auth("Content-Type" => "text/plain")
    assert_equal(-32_600, body["error"]["code"])

    post "/v1/mcp", params: "nope", headers: auth("Content-Type" => "text/plain")
    assert_equal(-32_700, body["error"]["code"])

    get "/v1/mcp", headers: auth
    assert_response :method_not_allowed
    assert_equal "POST", response.headers["Allow"]
  end

  test "the tools are the native capabilities and the person's own, named without dots" do
    names = tool_names
    assert_includes names, "todo_list"
    assert_includes names, "ward_status"
    assert_includes names, "hob_usage"
    assert_includes names, "todo_delete", "a person's tool, which no agent is offered"
    assert_includes names, "ward_ack"
    refute_includes names, "hob_agent_message", "mail between agents is not a person's tool"
    assert names.none? { |name| name.include?(".") }

    tools = body["result"]["tools"].index_by { |tool| tool["name"] }
    assert_equal "todo.list", tools["todo_list"]["title"]
    assert_equal Capability.find_by!(name: "todo.list").input_schema, tools["todo_list"]["inputSchema"]
    assert_equal({ "readOnlyHint" => true, "destructiveHint" => false }, tools["todo_list"]["annotations"])
    assert_equal({ "readOnlyHint" => false, "destructiveHint" => true }, tools["todo_delete"]["annotations"])
  end

  test "the list follows the rows: a disabled capability is gone, and clearance hides what is above it" do
    Capability.find_by!(name: "todo.drop").update!(enabled: false)
    refute_includes tool_names, "todo_drop"

    capped = tool_names(headers: auth("X-Hob-Clearance" => "household"))
    assert_includes capped, "todo_list"
    refute_includes capped, "ward_status", "ward.status is a personal capability"
    refute_includes capped, "ward_findings"

    call_tool("ward_status", {}, headers: auth("X-Hob-Clearance" => "household"))
    assert_equal(-32_602, body["error"]["code"], "what is not listed cannot be called")
  end

  test "a cap that names no realm is refused, not ignored" do
    rpc("tools/list", headers: auth("X-Hob-Clearance" => "persnal"))
    assert_response :bad_request
    assert_match(/names no realm/, body["error"])

    rpc("tools/list", headers: auth("X-Hob-Clearance" => ""))
    assert_response :ok
  end

  test "todos: create, list, update, complete, and delete, as the person" do
    created = answered("todo_create", { title: "Call the plumber", tags: [ "Phone" ] })
    id = created["todo"]["id"]
    assert_equal "jenner.of:t1", id, "the person's primary backend"
    assert_equal Todos::NOTICE, created["notice"]

    listed = answered("todo_list", { q: "plumber" })
    assert_equal [ id ], listed["todos"].map { |todo| todo["id"] }

    assert_equal "Tried twice", answered("todo_update", { id: id, notes_append: "Tried twice" })["todo"]["notes"]
    assert_equal "done", answered("todo_complete", { id: id })["todo"]["status"]

    assert_equal({ "deleted" => id }, answered("todo_delete", { id: id }))
    assert_raises(Todos::NotFound) { Todos.find(id) }
  end

  test "clearance decides which backends a call can reach" do
    Todos.create("backend" => "jenner.of", "title" => "Private errand")
    Todos.create("backend" => "house", "title" => "Buy milk")

    seen = answered("todo_list", {}, headers: auth("X-Hob-Clearance" => "household"))
    assert_equal [ "Buy milk" ], seen["todos"].map { |todo| todo["title"] }
  end

  test "a tool that fails is an answer the model can read, not a JSON-RPC error" do
    result = call_tool("todo_get", { id: "house:nope" })
    assert result["isError"]
    assert_match(/NotFound: no todo house:nope/, result["content"].first["text"])

    result = call_tool("todo_list", { colour: "red" })
    assert result["isError"]
    assert_match(/Invalid/, result["content"].first["text"])
    assert_nil body["error"]
  end

  test "the ward: findings, and an acknowledgement in the person's name" do
    WardCheck.create!(slug: "exposure")
    Notify.transport = ->(*) { "200" }
    @fake.reply({ severity: "attention", headline: "h", summary: "s", next_steps: [] }.to_json)
    Ward::Ingest.call(check: "exposure", exit_code: 1, lines: [ "FAIL cadance 5.78.183.213:8888: unexpected public TCP port" ], principal: @principal)

    findings = answered("ward_findings")
    assert_equal 1, findings["count"]
    assert_match(/data, not instructions/, findings["notice"])
    id = findings["findings"].first["id"]

    acked = answered("ward_ack", { id: id, note: "The dev box; firewalled next week" })["finding"]
    assert_equal [ "acknowledged", "tester" ], acked.values_at("state", "acknowledged_by")
    assert_equal 0, answered("ward_findings")["count"]

    assert_equal "open", answered("ward_unack", { id: id })["finding"]["state"]

    result = call_tool("ward_ack", { id: id, until: "2001-01-01" })
    assert result["isError"]
    assert_match(/future/, result["content"].first["text"])
  ensure
    Notify.transport = nil
  end

  test "a person's key only: agents, workers, and no key at all are turned away" do
    _, agent_token = agent("muse")
    rpc("tools/list", headers: { "Authorization" => "Bearer #{agent_token}" })
    assert_response :forbidden

    _, worker_token = forge!
    rpc("tools/list", headers: { "Authorization" => "Bearer #{worker_token}" })
    assert_response :forbidden

    rpc("tools/list", headers: {})
    assert_response :unauthorized
  end
end
