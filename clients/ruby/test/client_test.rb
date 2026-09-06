require_relative "test_helper"

class ClientTest < Minitest::Test
  TOOLS = [ { name: "lookup", description: "Look up", input_schema: { type: "object" } } ].freeze

  def setup
    @http = FakeHTTP.new
    @hob = Hob::Client.new(http: @http)
  end

  def test_complete_posts_the_request_and_wraps_the_reply
    @http.respond("id" => "c1", "status" => "success", "content" => '{"title":"Soup"}', "parsed" => { "title" => "Soup" },
                  "usage" => { "input_tokens" => 100, "output_tokens" => 10, "cost" => 0.00045 }, "model" => "claude-sonnet-5",
                  "provider" => "anthropic", "snapshot" => "abc", "tool_calls" => [])
    completion = @hob.complete(role: "extractor", operation: "recipe.extract", system: "Extract.",
                               messages: [ { role: "user", content: "Soup" } ], schema: { type: "object" }, metadata: { recipe: 7 })

    request = @http.requests.last
    assert_equal "/v1/completions", request.path
    assert_equal "extractor", request.body[:role]
    assert_equal({ recipe: 7 }, request.body[:metadata])
    refute request.body.key?(:params), "empty params are omitted"
    assert completion.success?
    assert_equal({ "title" => "Soup" }, completion.parsed)
    assert_equal 100, completion.usage.input_tokens
    assert_in_delta 0.00045, completion.usage.cost
    assert_equal "c1", completion.id
    refute completion.tool_calls?
  end

  def test_a_refusal_raises_with_the_completion_attached
    @http.respond("id" => "c2", "status" => "refused", "error" => "declined", "usage" => { "input_tokens" => 10 })
    error = assert_raises(Hob::Refused) { @hob.complete(role: "chat-default", messages: [ { role: "user", content: "x" } ]) }
    assert_equal "c2", error.completion.id
    assert_equal 10, error.completion.usage.input_tokens
  end

  def test_the_tool_loop_resumes_by_id
    @http.respond("id" => "c3", "status" => "tool_calls", "content" => "", "usage" => {},
                  "tool_calls" => [ { "id" => "call_1", "name" => "lookup", "arguments" => { "q" => "bees" }, "node" => "n1" } ])
    completion = @hob.complete(role: "extractor", messages: [ { role: "user", content: "bees?" } ], tools: TOOLS)
    assert completion.tool_calls?
    call = completion.tool_calls.first
    assert_equal "lookup", call.name
    assert_equal({ "q" => "bees" }, call.arguments)

    @http.respond("id" => "c3", "status" => "success", "content" => "Bees are fine.", "usage" => {}, "tool_calls" => [])
    resumed = @hob.complete(id: completion.id, tool_results: [ call.result({ ok: true }) ])
    assert_equal "Bees are fine.", resumed.content
    assert_equal({ id: "c3", tool_results: [ { id: "call_1", content: '{"ok":true}' } ] }, @http.requests.last.body)
  end

  def test_complete_needs_a_role_or_an_id
    assert_raises(ArgumentError) { @hob.complete(messages: []) }
  end

  def test_complete_streams_events_to_the_block
    @http.stream_events({ "type" => "delta", "content" => "Hel" }, { "type" => "delta", "content" => "lo" },
                        { "type" => "usage", "input_tokens" => 1 },
                        { "type" => "done", "id" => "c4", "status" => "success", "content" => "Hello", "usage" => { "input_tokens" => 1 } })
    text = +""
    completion = @hob.complete(role: "narrator", messages: [ { role: "user", content: "hi" } ]) { |e| text << e.content if e.delta? }
    assert @http.requests.last.stream
    assert_equal "Hello", text
    assert_equal "Hello", completion.content
  end

  def test_a_stream_error_event_raises
    @http.stream_events({ "type" => "error", "status" => "rate_limited", "message" => "slow down" })
    assert_raises(Hob::RateLimited) { @hob.complete(role: "narrator", messages: [ { role: "user", content: "hi" } ]) { |_| } }
  end

  def test_chat_returns_a_turn_and_streams
    @http.respond("status" => "success", "user" => { "hash" => "u1", "content" => "hi" },
                  "assistant" => { "hash" => "a1", "content" => "Hello." }, "assistants" => [ { "hash" => "a1", "content" => "Hello." } ],
                  "tool_calls" => [], "snapshot" => "s1")
    turn = @hob.chat(conversation: "conv_1", content: "hi", persona: "saffron", context: [ { name: "recipe", body: "Soup" } ])
    assert_equal "/v1/conversations/conv_1/chat", @http.requests.last.path
    assert_equal "main", @http.requests.last.body[:branch]
    assert_equal "Hello.", turn.content
    refute turn.tool_calls?

    @http.stream_events({ "type" => "delta", "content" => "Sure" },
                        { "type" => "tool_call", "id" => "call_1", "name" => "add_to_plan", "arguments" => {} },
                        { "type" => "done", "status" => "tool_calls", "assistant" => { "content" => "Sure" },
                          "tool_calls" => [ { "id" => "call_1", "name" => "add_to_plan", "arguments" => {} } ] })
    seen = []
    turn = @hob.chat(conversation: Hob::Conversation.new("id" => "conv_1"), content: "plan soup", tools: TOOLS) { |e| seen << e.type }
    assert_equal %w[delta tool_call done], seen
    assert turn.tool_calls?
    assert_equal "add_to_plan", turn.tool_calls.first.name
  end

  def test_chat_refusal_raises
    @http.respond("status" => "refused", "error" => "no")
    assert_raises(Hob::Refused) { @hob.chat(conversation: "conv_1", content: "x") }
  end

  def test_conversations_paths
    @http.respond("id" => "conv_9", "kind" => "chat", "branches" => [ "main" ])
    convo = @hob.conversations.create(title: "Dinner", realm: "household")
    assert_equal "conv_9", convo.id
    assert_equal({ title: "Dinner", realm: "household" }, @http.requests.last.body)

    @http.respond("id" => "conv_9", "messages" => [ { "role" => "user" } ])
    assert_equal 1, @hob.conversations.show("conv_9", branch: "alt").messages.size
    assert_equal({ branch: "alt" }, @http.requests.last.query)

    @http.respond("name" => "alt", "head" => "n1")
    @hob.conversations.fork("conv_9", name: "alt", at: "n1")
    assert_equal [ :post, "/v1/conversations/conv_9/branches" ], [ @http.requests.last.method, @http.requests.last.path ]

    @http.respond("name" => "main", "head" => "n2")
    @hob.conversations.set_head("conv_9", head: "n2")
    assert_equal [ :patch, "/v1/conversations/conv_9/branches/main", { head: "n2" } ],
                 [ @http.requests.last.method, @http.requests.last.path, @http.requests.last.body ]

    @http.respond([ { "hash" => "n1" }, { "hash" => "n3" } ])
    assert_equal 2, @hob.conversations.siblings("conv_9", "n1").size
    assert_equal "/v1/conversations/conv_9/nodes/n1/siblings", @http.requests.last.path

    @http.respond("hash" => "e1", "role" => "event")
    @hob.conversations.event("conv_9", content: "Added soup to the plan", meta: { recipe: 7 })
    assert_equal "/v1/conversations/conv_9/events", @http.requests.last.path
    assert_equal "Added soup to the plan", @http.requests.last.body[:content]

    @http.respond([ { "id" => "conv_9", "kind" => "pipeline" } ])
    assert_equal "pipeline", @hob.conversations.list(kind: "pipeline").first.kind
  end

  def test_usage_and_completion_lookup
    @http.respond("calls" => 3, "cost" => 0.01, "by_role" => { "extractor" => { "calls" => 3 } }, "recent" => [])
    usage = @hob.usage(ref: "recipe/7", since: Time.utc(2026, 9, 1))
    assert_equal 3, usage.calls
    assert_equal({ ref: "recipe/7", since: "2026-09-01T00:00:00Z" }, @http.requests.last.query.compact)

    @http.respond("id" => "c1", "status" => "tool_calls", "tool_calls" => [ { "id" => "call_1", "name" => "lookup" } ])
    found = @hob.completion("c1")
    assert_equal "/v1/completions/c1", @http.requests.last.path
    assert found.tool_calls?
  end

  def test_client_needs_base_and_key_without_an_injected_http
    assert_raises(ArgumentError) { Hob::Client.new(base: nil, key: "k") }
    assert_raises(ArgumentError) { Hob::Client.new(base: "http://x", key: nil) }
  end
end
