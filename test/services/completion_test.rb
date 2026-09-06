require "test_helper"

class CompletionTest < ActiveSupport::TestCase
  SCHEMA = { "type" => "object" }.freeze

  test "a completion is a pipeline conversation with input nodes, a snapshot, a reply node, and a ledger ref" do
    @fake.reply('{"title": "Soup"}')
    result = Completion.new(
      role: "extractor", operation: "recipe.extract", realm: "household",
      messages: [ { "role" => "system", "content" => "Extract." }, { "role" => "user", "content" => "Soup: boil water" } ],
      schema: SCHEMA, metadata: { "recipe" => 7 }, ref: "recipe/7"
    ).call

    convo = result.conversation
    assert convo.pipeline?
    assert_equal "recipe.extract", convo.title
    assert_equal "household", convo.realm
    assert_equal %w[user assistant], convo.branch.timeline.map(&:role)
    assert_equal({ "title" => "Soup" }, result.response.parsed)
    assert_equal true, result.assistant_node.meta["parsed"]
    assert_equal "Extract.", @fake.calls.last.system
    assert_equal "Extract.", result.snapshot.assembled["system"]
    assert_equal SCHEMA, result.snapshot.assembled["schema"]
    assert_equal result.snapshot.digest, result.assistant_node.prompt_snapshot_hash

    event = UsageEvent.last
    assert_equal "recipe/7", event.ref
    assert_equal({ "recipe" => 7, "conversation" => convo.id }, event.metadata)
    assert_equal result.snapshot.digest, event.snapshot_digest

    found = Completion.find(convo.id)
    assert_equal({ "title" => "Soup" }, found[:parsed])
  end

  test "a persona supplies the system prompt and the reply's speaker" do
    fable = persona("fable", system_core: "You narrate.")
    @fake.reply("Once upon a time.")
    result = Completion.new(role: "chat-default", persona: fable, realm: "household",
                            messages: [ user_message("a story") ]).call
    assert_equal "You narrate.", @fake.calls.last.system
    assert_equal "fable", result.assistant_node.speaker
    assert_equal "conversation/#{result.conversation.id}", UsageEvent.last.ref
  end

  test "a refusal keeps the input, records no reply node, and is not an error" do
    @fake.refuse
    result = Completion.new(role: "chat-default", realm: "household", messages: [ user_message("no") ]).call
    assert result.refused?
    assert_nil result.assistant_node
    assert_equal [ "user" ], result.conversation.message_nodes.pluck(:role)
    assert_equal "refused", Completion.find(result.conversation.id)[:reply].nil? ? "refused" : "success"
  end
end

class CompletionToolsTest < ActiveSupport::TestCase
  TOOLS = [ { "name" => "fetch_articles", "description" => "Fetch", "input_schema" => { "type" => "object", "properties" => { "ids" => { "type" => "array" } } } } ].freeze
  SCHEMA = { "type" => "object" }.freeze

  test "a completion pauses at tool calls and resumes from its id with the schema still in force" do
    @fake.call_tool("fetch_articles", { ids: [ 1, 2 ] }, id: "call_1")
    result = Completion.new(role: "extractor", operation: "feed.summarize", realm: "personal", schema: SCHEMA,
                            tools: TOOLS, messages: [ user_message("summarize the feed") ], max_iterations: 3).call
    assert result.tool_calls?
    assert_equal "tool_calls", result.status
    assert_nil result.assistant_node
    assert_equal [ { "id" => "call_1", "name" => "fetch_articles", "arguments" => { "ids" => [ 1, 2 ] } } ], result.tool_calls
    assert_equal TOOLS, result.snapshot.assembled["tools"]
    assert_equal "extractor", result.snapshot.assembled["role"]
    assert_equal result.tool_call_nodes.last.content_hash, result.conversation.branch.reload.head_hash

    found = Completion.find(result.conversation.id)
    assert_equal "tool_calls", found[:status]
    assert_equal "call_1", found[:tool_calls].first["id"]

    @fake.reply('{"summaries": []}')
    resumed = Completion.resume(result.conversation, tool_results: [ { "id" => "call_1", "content" => "[article 1, article 2]" } ])
    assert_equal "success", resumed.status
    assert_equal({ "summaries" => [] }, resumed.response.parsed)
    assert_equal SCHEMA, @fake.calls.last.schema
    assert_equal TOOLS, @fake.calls.last.tools
    assert_equal %w[user assistant tool], @fake.calls.last.messages.map { |m| m["role"] }
    assert_equal "feed.summarize", UsageEvent.last.operation
    assert_equal 2, UsageEvent.where(ref: "conversation/#{result.conversation.id}").count
    assert_equal "success", Completion.find(result.conversation.id)[:status]
    assert_equal({ "summaries" => [] }, Completion.find(result.conversation.id)[:parsed])
  end

  test "resume rejects a plain chat conversation and a completion without pending calls" do
    assert_raises(Gateway::Invalid) { Completion.resume(conversation, tool_results: []) }
    @fake.reply("hi")
    done = Completion.new(role: "chat-default", realm: "household", messages: [ user_message("x") ]).call
    assert_raises(Gateway::Invalid) { Completion.resume(done.conversation, tool_results: [ { id: "a", content: "b" } ]) }
  end
end
