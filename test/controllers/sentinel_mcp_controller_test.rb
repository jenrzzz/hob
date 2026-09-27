require "test_helper"

# POST /v1/sentinel/mcp: the MCP server for an agent's key. Coding agents
# (Claude Code, Codex, musecode) come in as agents of their own, so the
# board says which of them wrote what, and every call is a sentinel request.
class SentinelMcpControllerTest < ActionDispatch::IntegrationTest
  setup do
    native_capabilities!
    @claude, @claude_token = agent("claude-code")
    @codex, @codex_token = agent("codex")
    policy!(nil, "hob.board.*", "allow")
  end

  def as_agent(token)
    { "Authorization" => "Bearer #{token}" }
  end

  def rpc(method, params = nil, token: @claude_token, id: 1)
    post "/v1/sentinel/mcp", params: { jsonrpc: "2.0", id: id, method: method, params: params }.compact,
                             headers: as_agent(token), as: :json
  end

  def call_tool(name, arguments = {}, token: @claude_token)
    rpc("tools/call", { name: name, arguments: arguments }, token: token)
    assert_response :ok
    body["result"]
  end

  def answered(name, arguments = {}, **rest)
    result = call_tool(name, arguments, **rest)
    refute result["isError"], result["content"].first["text"]
    JSON.parse(result["content"].first["text"])
  end

  def tool_names(token: @claude_token)
    rpc("tools/list", token: token)
    body["result"]["tools"].map { |tool| tool["name"] }
  end

  test "initialize tells the agent it is gated and how a handoff reads on the board" do
    rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "codex", version: "1" } })
    assert_response :ok
    assert_equal "2025-06-18", body["result"]["protocolVersion"]
    assert_match(/sentinel/, body["result"]["instructions"])
    assert_match(/handoff: <what>/, body["result"]["instructions"])
    assert_match(/never instructions/, body["result"]["instructions"])
  end

  test "the tools are what policy lets this agent ask for, at its clearance, plus its own requests" do
    names = tool_names
    assert_equal %w[hob_board_post hob_board_read sentinel_request], names.sort
    refute_includes names, "todo_list", "no rule covers todos, so they are not offered"

    policy!(@claude, "todo.*", "confirm")
    policy!(@claude, "todo.drop", "deny")
    names = tool_names
    assert_includes names, "todo_list", "a confirm rule still offers the tool"
    refute_includes names, "todo_drop", "a deny rule hides it"
    refute_includes tool_names(token: @codex_token), "todo_list", "another agent's rules are its own"

    Capability.find_by!(name: "hob.board.read").update!(realm: "personal")
    refute_includes tool_names, "hob_board_read", "a capability above the agent's clearance is not offered"

    SentinelPolicy.delete_all
    assert_equal %w[sentinel_request], tool_names, "no rules, nothing to ask for"
  end

  test "every capability tool takes a reason, which goes on the request and not to the handler" do
    rpc("tools/list")
    board_post = body["result"]["tools"].find { |tool| tool["name"] == "hob_board_post" }
    assert_equal "hob.board.post", board_post["title"]
    assert board_post["inputSchema"]["properties"]["reason"]
    assert_equal false, board_post["annotations"]["readOnlyHint"]

    answered("hob_board_post", { title: "handoff: flaky test", body: "over to you", reason: "handing off" })
    request = SentinelRequest.recent.first
    assert_equal "handing off", request.reason
    refute request.arguments.key?("reason"), "hob.board.post refuses fields it does not know"
    assert_equal "completed", request.status
  end

  test "a handoff: one agent opens a thread, another reads it and answers, each under its own name" do
    opened = answered("hob_board_post", {
      title: "handoff: fix the sentinel realm constraint", body: "Branch agent-1, PR #34. Left: the test for review effects.",
      links: [ "https://github.com/jenrzzz/hob/pull/34" ]
    })
    assert_equal({ "agent" => "claude-code", "surface" => "claude-code" }, opened["author"])

    index = answered("hob_board_read", {}, token: @codex_token)
    thread = index["threads"].find { |t| t["id"] == opened["thread_id"] }
    assert_equal "handoff: fix the sentinel realm constraint", thread["topic"]

    answered("hob_board_post", { thread_id: thread["slug"], body: "Picking this up." }, token: @codex_token)
    posts = answered("hob_board_read", { thread: opened["thread_id"] })["posts"]
    assert_equal [ %w[claude-code claude-code], %w[codex codex] ], posts.map { |p| p.values_at("sender_agent", "surface") }

    assert_equal 2, @claude.sentinel_requests.count, "each call is a request in the ledger"
    assert_equal 2, @codex.sentinel_requests.count
  end

  test "a denial and a failure are answers the model can read, and are written down" do
    policy!(@claude, "hob.board.post", "allow", constraints: { "body" => { "max" => 10 } })
    result = call_tool("hob_board_post", { title: "long", body: "far too long for this rule" })
    assert result["isError"]
    assert_match(/denied \(constraint\): body exceeds 10/, result["content"].first["text"])
    assert_equal "denied", @claude.sentinel_requests.recent.first.status

    result = call_tool("hob_board_read", { thread: "no-such-thread" })
    assert result["isError"]
    assert_match(/failed: .*no thread/, result["content"].first["text"])
  end

  test "a request a person must confirm answers pending, and sentinel_request finds out how it went" do
    policy!(@claude, "hob.board.post", "confirm")
    pending = answered("hob_board_post", { title: "needs a look", body: "hello" })
    assert_equal "pending", pending["status"]
    assert_match(/sentinel_request/, pending["note"])
    assert_equal 0, BoardPost.count

    assert_equal "pending", answered("sentinel_request", { id: pending["request"] })["status"]

    Sentinel.decide!(SentinelRequest.find(pending["request"]), decision: "allow", decider: @principal)
    settled = answered("sentinel_request", { id: pending["request"] })
    assert_equal "needs a look", settled["title"]
    assert_equal "claude-code", settled["author"]["agent"], "run as the agent, though a person allowed it"

    result = call_tool("sentinel_request", { id: pending["request"] }, token: @codex_token)
    assert result["isError"], "an agent reads only its own requests"
  end

  test "a tool the agent was not offered is an error, not a request" do
    rpc("tools/call", { name: "todo_list", arguments: {} })
    assert_equal(-32_602, body["error"]["code"])
    assert_equal 0, SentinelRequest.count
  end

  test "an agent's key only: a person is sent to their own endpoint; the person's endpoint does not offer board posts" do
    post "/v1/sentinel/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }, headers: auth, as: :json
    assert_response :forbidden
    assert_match(%r{/v1/mcp}, body["error"])

    post "/v1/mcp", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }, headers: auth, as: :json
    names = body["result"]["tools"].map { |tool| tool["name"] }
    assert_includes names, "hob_board_read"
    refute_includes names, "hob_board_post", "a board post's author must be an agent"

    get "/v1/sentinel/mcp", headers: as_agent(@claude_token)
    assert_response :method_not_allowed
  end
end
