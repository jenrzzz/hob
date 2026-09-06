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
