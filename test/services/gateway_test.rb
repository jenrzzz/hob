require "test_helper"

class GatewayTest < ActiveSupport::TestCase
  SCHEMA = { "type" => "object", "properties" => { "name" => { "type" => "string" } } }.freeze

  test "complete returns a normalized response, streams deltas, and meters a priced success row" do
    @fake.reply("Hello there, friend.", input_tokens: 1000, output_tokens: 100, cache_read_tokens: 500)
    deltas = []
    response = Gateway.complete(role: "chat-default", messages: [ user_message("hi") ], system: "Be brief",
                                operation: "test.greet", ref: "thing/1") { |type, text| deltas << text if type == :delta }

    assert_equal "Hello there, friend.", response.content
    assert_equal "Hello there, friend.", deltas.join
    assert_equal "end_turn", response.stop_reason
    refute response.refused?
    assert_equal "claude-sonnet-5", response.model
    assert_equal "anthropic", response.provider
    assert_kind_of Integer, response.duration_ms

    call = @fake.calls.last
    assert_equal "Be brief", call.system
    assert_equal({ "max_tokens" => 4096 }, call.params)

    event = UsageEvent.last
    assert_equal %w[chat-default anthropic claude-sonnet-5 test.greet success thing/1],
                 [ event.role, event.provider, event.model, event.operation, event.status, event.ref ]
    assert_equal 1000, event.units["input_tokens"]
    assert_equal 500, event.units["cache_read_tokens"]
    assert_in_delta 0.00465, event.cost.to_f, 1e-6 # 1000*3 + 100*15 + 500*0.3 per million
    assert_equal @principal, event.principal
    assert_equal "test", event.surface
  end

  test "request params deep-merge over the chain link's" do
    @fake.reply("ok")
    Gateway.complete(role: "interviewer", messages: [ user_message("q") ],
                     params: { "output_config" => { "effort" => "high" }, "max_tokens" => 2 })
    assert_equal({ "thinking" => { "type" => "adaptive" }, "output_config" => { "effort" => "high" }, "max_tokens" => 2 },
                 @fake.calls.last.params)
  end

  test "a refusal is a distinct, metered outcome, not an error" do
    @fake.refuse
    response = Gateway.complete(role: "chat-default", messages: [ user_message("do something bad") ])
    assert response.refused?
    assert_equal "refused", response.status
    assert_equal "refused", UsageEvent.last.status

    @fake.reply("", stop_reason: "end_turn")
    assert Gateway.complete(role: "chat-default", messages: [ user_message("x") ]).refused?, "empty content is a refusal"
  end

  test "schema replies are parsed with hygiene" do
    @fake.reply("```json\n{\"name\": \"Ada\", \"tags\": \"[\\\"x\\\"]\"}\n```")
    response = Gateway.complete(role: "extractor", messages: [ user_message("extract") ], schema: SCHEMA)
    assert_equal({ "name" => "Ada", "tags" => [ "x" ] }, response.parsed)
    assert_equal SCHEMA, @fake.calls.last.schema
    assert_equal "success", UsageEvent.last.status
  end

  test "an unparseable structured reply is retried exactly once and both attempts are metered" do
    @fake.reply("I'd rather write prose.").reply('{"name": "Ada"}')
    events = []
    response = Gateway.complete(role: "extractor", messages: [ user_message("extract") ], schema: SCHEMA) { |t, v| events << [ t, v ] }

    assert_equal({ "name" => "Ada" }, response.parsed)
    assert_equal 2, @fake.calls.size
    assert_includes events, [ :retry, "unparseable structured output" ]
    assert_equal %w[error success], UsageEvent.order(:id).last(2).map(&:status)
    assert_match(/did not parse/, UsageEvent.order(:id).last(2).first.error)
  end

  test "two unparseable structured replies are a refusal" do
    @fake.reply("no").reply("still no")
    assert_raises(Gateway::Refused) do
      Gateway.complete(role: "extractor", messages: [ user_message("extract") ], schema: SCHEMA)
    end
    assert_equal %w[error refused], UsageEvent.order(:id).last(2).map(&:status)
  end

  test "an unavailable provider falls through to the next link, metering the failure" do
    @fake.fail(Gateway::Unavailable.new("overloaded")).reply("from backup")
    response = Gateway.complete(role: "extractor", messages: [ user_message("x") ])

    assert_equal "from backup", response.content
    assert_equal "backup", response.provider
    assert_equal %w[error success], UsageEvent.order(:id).last(2).map(&:status)
    assert_equal %w[anthropic backup], UsageEvent.order(:id).last(2).map(&:provider)
    assert_equal "Unavailable: overloaded", UsageEvent.order(:id).last(2).first.error
  end

  test "rate limits fall through too and are metered as rate_limited" do
    @fake.fail(Gateway::RateLimited.new("slow down", retry_after: 7)).reply("ok")
    Gateway.complete(role: "extractor", messages: [ user_message("x") ])
    assert_equal "rate_limited", UsageEvent.order(:id).last(2).first.status
  end

  test "the last link's failure is raised" do
    @fake.fail(Gateway::Unavailable.new("a")).fail(Gateway::RateLimited.new("b", retry_after: 3))
    error = assert_raises(Gateway::RateLimited) { Gateway.complete(role: "extractor", messages: [ user_message("x") ]) }
    assert_equal 3, error.retry_after
  end

  test "strict links do not fall through" do
    @fake.fail(Gateway::Unavailable.new("opus down"))
    assert_raises(Gateway::Unavailable) { Gateway.complete(role: "interviewer", messages: [ user_message("x") ]) }

    assert_raises(Gateway::NoProviderError) { Gateway.complete(role: "strict-offline", messages: [ user_message("x") ]) }

    @fake.reply("fine")
    assert_equal "anthropic", Gateway.complete(role: "lenient-offline", messages: [ user_message("x") ]).provider
  end

  test "bad requests are Invalid before any provider call" do
    assert_raises(Gateway::UnknownRoleError) { Gateway.complete(role: "nope", messages: [ user_message("x") ]) }
    assert_raises(Gateway::Invalid) { Gateway.complete(role: "chat-default", messages: [ { "role" => "assistant", "content" => "x" } ]) }
    assert_raises(Gateway::Invalid) { Gateway.complete(role: "chat-default", messages: [ { "role" => "system", "content" => "x" } ]) }
    assert_empty @fake.calls
  end

  test "the ledger never raises" do
    @fake.reply("ok")
    ModelPrice.singleton_class.alias_method(:original_cost_for, :cost_for)
    ModelPrice.define_singleton_method(:cost_for) { |**| raise "db down" }
    assert_equal "ok", Gateway.complete(role: "chat-default", messages: [ user_message("x") ]).content
    assert_nil UsageEvent.last
  ensure
    ModelPrice.singleton_class.alias_method(:cost_for, :original_cost_for)
  end
end

class GatewayToolsTest < ActiveSupport::TestCase
  TOOLS = [ { name: "lookup", description: "d", input_schema: { type: "object" } } ].freeze

  test "a tool-calling reply skips structured parsing and is metered as success" do
    @fake.call_tool("lookup", { q: 1 }, id: "c1")
    response = Gateway.complete(role: "extractor", messages: [ user_message("x") ], schema: { "type" => "object" }, tools: TOOLS)
    assert response.tool_calls?
    assert_nil response.parsed
    assert_equal "tool_calls", response.status
    refute response.refused?
    assert_equal "success", UsageEvent.last.status
    assert_equal 1, @fake.calls.size
  end

  test "tool messages may end the transcript; tool_choice is validated" do
    @fake.reply("ok")
    messages = [ user_message("x"),
                 { "role" => "assistant", "content" => "", "tool_calls" => [ { "id" => "c1", "name" => "lookup", "arguments" => {} } ] },
                 { "role" => "tool", "tool_call_id" => "c1", "content" => "r" } ]
    Gateway.complete(role: "chat-default", messages: messages, tools: TOOLS, tool_choice: "required")
    assert_equal "required", @fake.calls.last.tool_choice
    assert_equal "c1", @fake.calls.last.messages[1]["tool_calls"].first["id"]

    assert_raises(Gateway::Invalid) { Gateway.complete(role: "chat-default", messages: [ user_message("x") ], tools: TOOLS, tool_choice: "nope") }
    assert_raises(Gateway::Invalid) { Gateway.complete(role: "chat-default", messages: [ { "role" => "tool", "content" => "r" } ]) }
    assert_raises(Gateway::Invalid) { Gateway.complete(role: "chat-default", messages: [ user_message("x") ], tools: [ { name: "a" }, { name: "a" } ]) }
  end
end
