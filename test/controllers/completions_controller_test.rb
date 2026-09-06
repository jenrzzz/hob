require "test_helper"

class CompletionsControllerTest < ActionDispatch::IntegrationTest
  SCHEMA = { "type" => "object", "properties" => { "name" => { "type" => "string" } } }.freeze

  test "POST /v1/completions returns the parsed reply and persists a pipeline conversation" do
    @fake.reply('{"name": "Ada"}', input_tokens: 100, output_tokens: 10)
    post "/v1/completions", params: {
      role: "extractor", operation: "person.extract", system: "Extract a person.",
      messages: [ { role: "user", content: "Ada Lovelace wrote programs." } ], schema: SCHEMA,
      metadata: { note: 1 }, realm: "personal"
    }, headers: auth, as: :json

    assert_response :ok
    assert_equal "success", body["status"]
    assert_equal({ "name" => "Ada" }, body["parsed"])
    assert_equal 100, body.dig("usage", "input_tokens")
    assert_in_delta 0.00045, body.dig("usage", "cost"), 1e-6
    assert_equal "claude-sonnet-5", body["model"]
    assert_equal "assistant", body.dig("node", "role")

    convo = Conversation.find(body["id"])
    assert convo.pipeline?
    assert_equal "personal", convo.realm
    assert_equal "person.extract", UsageEvent.last.operation
    assert_equal "test", UsageEvent.last.surface

    get "/v1/completions/#{body['id']}", headers: auth
    assert_response :ok
    assert_equal({ "name" => "Ada" }, body["parsed"])
    assert_equal "person.extract", body["operation"]
  end

  test "a refusal is 200 with status refused" do
    @fake.refuse
    post "/v1/completions", params: { role: "chat-default", messages: [ { role: "user", content: "x" } ] }, headers: auth, as: :json
    assert_response :ok
    assert_equal "refused", body["status"]
    assert_nil body["content"]
    assert body["id"].present?
  end

  test "streams delta, usage, and done over SSE" do
    @fake.reply("Hello streaming world")
    post "/v1/completions", params: { role: "chat-default", messages: [ { role: "user", content: "hi" } ] },
         headers: auth("Accept" => "text/event-stream"), as: :json

    assert_response :ok
    assert_equal "text/event-stream", response.headers["Content-Type"]
    events = sse_events
    assert_equal "Hello streaming world", events.select { |e| e["type"] == "delta" }.map { |e| e["content"] }.join
    assert_equal %w[usage done], events.last(2).map { |e| e["type"] }
    assert_equal "success", events.last["status"]
  end

  test "a retry shows up on the stream" do
    @fake.reply("prose").reply('{"name": "Ada"}')
    post "/v1/completions", params: { role: "extractor", messages: [ { role: "user", content: "x" } ], schema: SCHEMA },
         headers: auth("Accept" => "text/event-stream"), as: :json
    assert_includes sse_events.map { |e| e["type"] }, "retry"
    assert_equal({ "name" => "Ada" }, sse_events.last["parsed"])
  end

  test "gateway outcomes map onto HTTP" do
    post "/v1/completions", params: { role: "nope", messages: [ { role: "user", content: "x" } ] }, headers: auth, as: :json
    assert_response :unprocessable_entity

    @fake.fail(Gateway::Unavailable.new("down")).fail(Gateway::Unavailable.new("down too"))
    post "/v1/completions", params: { role: "extractor", messages: [ { role: "user", content: "x" } ] }, headers: auth, as: :json
    assert_response :service_unavailable
    assert_equal "unavailable", body["status"]

    @fake.fail(Gateway::RateLimited.new("429", retry_after: 30))
    post "/v1/completions", params: { role: "chat-default", messages: [ { role: "user", content: "x" } ] }, headers: auth, as: :json
    assert_response :service_unavailable
    assert_equal "30", response.headers["Retry-After"]

    @fake.fail(Gateway::Unauthorized.new("bad key"))
    post "/v1/completions", params: { role: "chat-default", messages: [ { role: "user", content: "x" } ] }, headers: auth, as: :json
    assert_response :bad_gateway

    post "/v1/completions", params: { role: "chat-default", messages: [ { role: "user", content: "x" } ] }, as: :json
    assert_response :unauthorized
  end

  test "realm cannot exceed the key's clearance" do
    post "/v1/completions", params: { role: "chat-default", messages: [ { role: "user", content: "x" } ], realm: "intimate" },
         headers: auth("X-Hob-Clearance" => "household"), as: :json
    assert_response :unprocessable_entity
    assert_empty @fake.calls
  end
end

class CompletionsControllerToolsTest < ActionDispatch::IntegrationTest
  TOOLS = [ { name: "lookup", description: "Look up", input_schema: { type: "object", properties: { q: { type: "string" } } } } ].freeze

  test "a tool call comes back as status tool_calls and resumes with id + tool_results" do
    @fake.call_tool("lookup", { q: "bees" }, id: "call_1")
    post "/v1/completions", params: { role: "extractor", messages: [ { role: "user", content: "bees?" } ], tools: TOOLS },
         headers: auth, as: :json
    assert_response :ok
    assert_equal "tool_calls", body["status"]
    assert_equal "lookup", body["tool_calls"].first["name"]
    assert_equal({ "q" => "bees" }, body["tool_calls"].first["arguments"])
    assert body["tool_calls"].first["node"].present?
    assert_nil body["node"]
    id = body["id"]

    get "/v1/completions/#{id}", headers: auth
    assert_equal "tool_calls", body["status"]
    assert_equal "call_1", body["tool_calls"].first["id"]

    @fake.reply("Bees are fine.")
    post "/v1/completions", params: { id: id, tool_results: [ { id: "call_1", content: "ok" } ] }, headers: auth, as: :json
    assert_response :ok
    assert_equal "success", body["status"]
    assert_equal id, body["id"]
    assert_equal "Bees are fine.", body["content"]
    assert_equal %w[user assistant tool], @fake.calls.last.messages.map { |m| m["role"] }

    post "/v1/completions", params: { id: id, tool_results: [ { id: "call_1", content: "again" } ] }, headers: auth, as: :json
    assert_response :unprocessable_entity
  end

  test "tool_call events stream before usage and done" do
    @fake.call_tool("lookup", { q: "x" }, id: "call_9", content: "Checking")
    post "/v1/completions", params: { role: "chat-default", messages: [ { role: "user", content: "x" } ], tools: TOOLS },
         headers: auth("Accept" => "text/event-stream"), as: :json
    types = sse_events.map { |e| e["type"] }
    assert_equal %w[tool_call usage done], types.last(3)
    assert_equal "delta", types.first
    assert_equal "call_9", sse_events[-3]["id"]
    assert_equal "tool_calls", sse_events.last["status"]
  end

  test "bad tools are Invalid" do
    post "/v1/completions", params: { role: "chat-default", messages: [ { role: "user", content: "x" } ], tools: [ { name: "no spaces here" } ] },
         headers: auth, as: :json
    assert_response :unprocessable_entity
    post "/v1/completions", params: { role: "chat-default", messages: [ { role: "user", content: "x" } ], tools: TOOLS, tool_choice: "other" },
         headers: auth, as: :json
    assert_response :unprocessable_entity
    assert_empty @fake.calls
  end
end
