require "test_helper"

# The admin Usage pages: every gateway call, what it cost, and for any one
# call what it was asked, what it said, and the tools it called.
class AdminUsageControllerTest < ActionDispatch::IntegrationTest
  setup { admin_signing_in! }
  teardown { admin_signed_out! }

  test "needs a signed-in person" do
    get "/admin/usage"
    assert_redirected_to "/login"
  end

  test "an empty ledger renders" do
    admin_sign_in
    get "/admin/usage"
    assert_response :ok
    assert_select "#calls", /No calls match/
  end

  test "lists calls with spend, refusals and failures, filterable by status" do
    @fake.reply("hi", input_tokens: 1000, output_tokens: 100).refuse.fail(Gateway::Unavailable.new("upstream 529"))
    Gateway.complete(role: "chat-default", messages: [ user_message("a") ], operation: "greet")
    Gateway.complete(role: "chat-default", messages: [ user_message("b") ], operation: "probe")
    assert_raises(Gateway::Unavailable) { Gateway.complete(role: "chat-default", messages: [ user_message("c") ], operation: "probe") }

    admin_sign_in
    get "/admin/usage"
    assert_response :ok
    assert_select "#stats", /\$0\.0045|<\$0\.01/
    assert_select "#stats .stat", /1\s*refused/
    assert_select "#stats .stat", /1\s*failed/
    assert_select "#calls tbody tr", 3
    assert_select "#chart .bar"
    assert_select "#by-operation", /probe/

    get "/admin/usage", params: { status: "refused" }
    assert_select "#calls tbody tr", 1
    assert_select "#calls tbody", /probe/
    assert_select ".selection", /Refused/

    get "/admin/usage", params: { operation: "greet", group: "model", metric: "calls", period: "today" }
    assert_response :ok
    assert_select "#calls tbody tr", 1
  end

  test "a refused call shows what the model said, its prompt, and other calls in the conversation" do
    @fake.reply("I'd rather not.", stop_reason: "refusal")
    result = Completion.new(role: "chat-default", realm: "personal", system: "You sort mail.",
                            messages: [ user_message("Sort this <b>letter</b>") ], operation: "mail.sort").call
    event = UsageEvent.last

    admin_sign_in
    get "/admin/usage/#{event.id}"
    assert_response :ok
    assert_select "#outcome", /refused/
    assert_select "#outcome code", "refusal"
    assert_select "#response pre", "I'd rather not."
    assert_select "#prompt", /You sort mail\./
    assert_select "#prompt pre", "Sort this <b>letter</b>"
    assert_select "#facts", /conversation\/#{result.conversation.id}/
  end

  test "a tool call shows its arguments and the result that answered it" do
    @fake.call_tool("lookup", { q: "kettle" }, id: "toolu_1")
    result = Completion.new(role: "chat-default", realm: "household", messages: [ user_message("x") ], operation: "ask",
                            tools: [ { name: "lookup", description: "find", input_schema: { type: "object" } } ]).call
    calling = UsageEvent.last
    @fake.reply("It's in the cupboard.")
    Completion.resume(result.conversation, tool_results: [ { id: "toolu_1", content: "cupboard, top shelf" } ])

    admin_sign_in
    get "/admin/usage"
    assert_select "#tools", /lookup/
    assert_select "#calls .tools", /lookup/

    get "/admin/usage", params: { tool: "lookup" }
    assert_select "#calls tbody tr", 1

    get "/admin/usage/#{calling.id}"
    assert_response :ok
    assert_select "#tool-toolu_1 h3 code", "lookup"
    assert_select "#tool-toolu_1", /kettle/
    assert_select "#tool-toolu_1", /cupboard, top shelf/
    assert_select "#related tr", 2
  end

  test "what a call said stays hidden above the person's clearance; the cost does not" do
    clearance!("intimate")
    @fake.reply("very private", input_tokens: 1000, output_tokens: 100)
    Gateway.complete(role: "chat-default", messages: [ user_message("x") ], realm: "intimate", snapshot: "deadbeef")
    event = UsageEvent.last
    @principal.update!(max_clearance: "household")

    admin_sign_in
    get "/admin/usage/#{event.id}"
    assert_response :ok
    assert_select "#response", /above your clearance/
    assert_no_match(/very private/, response.body)
    assert_select "#metrics", /0\.004/
  end
end
