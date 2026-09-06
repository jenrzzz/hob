require "test_helper"

class ConversationsControllerTest < ActionDispatch::IntegrationTest
  test "a conversation is created at the requested realm, never above clearance" do
    post "/v1/conversations", params: { title: "Dinner", realm: "personal" }, headers: auth, as: :json
    assert_response :created
    assert_equal "personal", body["realm"]
    assert_equal [ "main" ], body["branches"]

    post "/v1/conversations", params: { realm: "personal" }, headers: auth("X-Hob-Clearance" => "household"), as: :json
    assert_response :unprocessable_entity
    assert_equal "realm above clearance", body["error"]
  end

  test "show returns the branch timeline including tool nodes" do
    convo = conversation
    @fake.call_tool("lookup", { q: "x" }, id: "c1")
    ChatTurn.new(conversation: convo, branch: convo.branch, content: "go",
                 tools: [ { name: "lookup", input_schema: { type: "object" } } ]).call
    get "/v1/conversations/#{convo.id}", headers: auth
    assert_response :ok
    assert_equal %w[text tool_call], body["messages"].map { |m| m["kind"] }
    assert_equal "c1", body["messages"].last["meta"]["tool_call_id"]
  end
end
