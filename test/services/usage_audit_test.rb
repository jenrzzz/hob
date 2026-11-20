require "test_helper"

# The ledger as an audit trail: what each gateway call said survives beside
# its row, at the call's realm, and writing it can never break the call.
class UsageAuditTest < ActiveSupport::TestCase
  SCHEMA = { "type" => "object", "properties" => { "name" => { "type" => "string" } } }.freeze

  test "a refusal keeps what the model said and why it stopped" do
    @fake.reply("I can't help with that.", stop_reason: "refusal")
    response = Gateway.complete(role: "chat-default", messages: [ user_message("x") ], operation: "probe", realm: "personal")

    assert response.refused?
    event = UsageEvent.last
    assert_equal %w[refused refusal personal], [ event.status, event.stop_reason, event.realm ]
    assert_equal "I can't help with that.", event.payload.response_content
    assert_equal "personal", event.payload.realm
  end

  test "both attempts at an unparseable structured reply keep their prose" do
    @fake.reply("Sorry, prose.").reply("Still prose.")
    assert_raises(Gateway::Refused) do
      Gateway.complete(role: "chat-default", messages: [ user_message("x") ], schema: SCHEMA, snapshot: "abc123")
    end

    first, second = UsageEvent.order(:id).last(2)
    assert_equal %w[error refused], [ first.status, second.status ]
    assert_equal [ "Sorry, prose.", "Still prose." ], [ first.payload.response_content, second.payload.response_content ]
    assert_equal [ "abc123", "abc123" ], [ first.snapshot_digest, second.snapshot_digest ]
    assert_nil second.payload.request, "the snapshot holds the request"
  end

  test "tool calls are named on the row, with their arguments in the payload" do
    @fake.call_tool("lookup", { q: "kettle" }, id: "toolu_1", content: "Let me check.")
    Gateway.complete(role: "chat-default", messages: [ user_message("x") ],
                     tools: [ { name: "lookup", description: "find", input_schema: { type: "object" } } ])

    event = UsageEvent.last
    assert_equal [ "lookup" ], event.tool_names
    assert_equal "tool_use", event.stop_reason
    assert_equal [ { "id" => "toolu_1", "name" => "lookup", "arguments" => { "q" => "kettle" } } ], event.payload.tool_calls
    assert_equal [ "lookup" ], event.payload.request["tools"], "no snapshot, so the request is kept"
    assert_equal "x", event.payload.request["messages"].last["content"]
  end

  test "the realm defaults to the clearance in force and hides the payload above a reader's" do
    clearance!("intimate")
    @fake.reply("secret reply")
    Gateway.complete(role: "chat-default", messages: [ user_message("x") ])
    event = UsageEvent.last
    assert_equal "intimate", event.realm

    clearance!("household")
    assert_nil UsageEvent.find(event.id).payload, "RLS hides the payload"
    assert UsageEvent.exists?(event.id), "but the ledger row is still counted"
  end

  test "a payload that can't be written loses the audit, not the call or the row" do
    clearance!("household")
    @fake.reply("fine")
    response = nil
    ActiveRecord::Base.transaction do
      response = Gateway.complete(role: "chat-default", messages: [ user_message("x") ], realm: "intimate")
      assert UsageEvent.count.positive?, "the transaction is still usable"
    end

    assert_equal "fine", response.content
    event = UsageEvent.last
    assert_equal "success", event.status
    clearance!("intimate")
    assert_nil UsagePayload.find_by(usage_event_id: event.id)
  end

  test "a completion's calls carry its conversation's realm" do
    @fake.reply("done")
    Completion.new(role: "chat-default", realm: "personal", messages: [ user_message("x") ], operation: "one").call
    assert_equal "personal", UsageEvent.last.realm
  end

  test "transport failures are metered without a payload" do
    @fake.fail(Gateway::Unauthorized.new("bad key"))
    assert_raises(Gateway::Unauthorized) { Gateway.complete(role: "chat-default", messages: [ user_message("x") ]) }
    event = UsageEvent.last
    assert_equal "error", event.status
    assert_nil event.payload
  end
end
