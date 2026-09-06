require "test_helper"

class UsageControllerTest < ActionDispatch::IntegrationTest
  test "summarizes the ledger for the calling surface, filterable by ref and role" do
    @fake.reply("a", input_tokens: 100, output_tokens: 10).reply("b", input_tokens: 50, output_tokens: 5).refuse
    Gateway.complete(role: "chat-default", messages: [ user_message("x") ], ref: "thing/1", operation: "one")
    Gateway.complete(role: "extractor", messages: [ user_message("x") ], ref: "thing/2", operation: "two")
    Gateway.complete(role: "chat-default", messages: [ user_message("x") ], ref: "thing/1", operation: "one")
    UsageEvent.record(surface: "other", role: "chat-default", model: "claude-sonnet-5", units: { "input_tokens" => 999 })

    get "/v1/usage", headers: auth
    assert_response :ok
    assert_equal 3, body["calls"]
    assert_equal({ "success" => 2, "refused" => 1 }, body["by_status"])
    assert_equal 160, body["input_tokens"], "a refusal still consumed input tokens"
    assert_in_delta 0.000705, body["cost"], 1e-6
    assert_equal %w[chat-default extractor], body["by_role"].keys.sort
    assert_equal 2, body.dig("by_operation", "one", "calls")
    assert_equal 3, body["recent"].size

    get "/v1/usage", params: { ref: "thing/1", role: "chat-default" }, headers: auth
    assert_equal 2, body["calls"]

    get "/v1/usage", params: { surface: "all" }, headers: auth
    assert_equal 4, body["calls"]

    get "/v1/usage", params: { since: 1.minute.from_now.iso8601 }, headers: auth
    assert_equal 0, body["calls"]
  end
end
