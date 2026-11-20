require "test_helper"

# Following a conversation: a bridge long-polls for the nodes after the one
# it last saw, and posts the whispers among them.
class NodesFollowTest < ActionDispatch::IntegrationTest
  setup do
    @convo = conversation(realm: "personal")
  end

  def append(role, text, meta: {})
    branch = @convo.branch
    node = MessageNode.append!(conversation: @convo, parent_hash: branch.head_hash, role: role, content: text, meta: meta)
    branch.advance!(node)
    node
  end

  test "without after, the head to follow from; with it, what came since" do
    first = append("user", "hi")
    get "/v1/conversations/#{@convo.id}/nodes", headers: auth
    assert_equal({ "head" => first.content_hash, "nodes" => [] }, body)

    append("assistant", "hey")
    whisper = append("assistant", "rar", meta: { "whisper" => true })
    get "/v1/conversations/#{@convo.id}/nodes", params: { after: first.content_hash }, headers: auth
    assert_equal whisper.content_hash, body["head"]
    assert_equal [ "hey", "rar" ], body["nodes"].map { |n| n["content"] }
    assert_equal true, body["nodes"].last["meta"]["whisper"]
  end

  test "an after no longer on the branch says so" do
    append("user", "hi")
    get "/v1/conversations/#{@convo.id}/nodes", params: { after: "gone" }, headers: auth
    assert_equal true, body["missing"]
    assert_empty body["nodes"]
  end

  test "a wait returns as soon as the head moves, and empty when it doesn't" do
    head = append("user", "hi")
    get "/v1/conversations/#{@convo.id}/nodes", params: { after: head.content_hash, wait: 1 }, headers: auth
    assert_response :ok
    assert_empty body["nodes"]
    assert_equal head.content_hash, body["head"]
  end
end
