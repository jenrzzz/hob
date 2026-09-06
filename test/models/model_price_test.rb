require "test_helper"

class ModelPriceTest < ActiveSupport::TestCase
  test "longest prefix wins and dated ids match family rows" do
    ModelPrice.create!(model: "claude-haiku-4-5", input: 1, output: 5)
    ModelPrice.create!(model: "claude-haiku-4-5-20251001", input: 0.8, output: 4)

    assert_equal "claude-haiku-4-5", ModelPrice.for_model("claude-haiku-4-5-99999999").model
    assert_equal "claude-haiku-4-5-20251001", ModelPrice.for_model("claude-haiku-4-5-20251001").model
    assert_nil ModelPrice.for_model("gpt-test")
  end

  test "cost covers all four token kinds and is nil for unpriced models" do
    units = { "input_tokens" => 1_000_000, "output_tokens" => 100_000, "cache_read_tokens" => 1_000_000, "cache_creation_tokens" => 0 }
    assert_equal 4.8, ModelPrice.cost_for(model: "claude-sonnet-5", units: units).to_f
    assert_nil ModelPrice.cost_for(model: "gpt-test", units: units)
  end
end

class MessageNodeTest < ActiveSupport::TestCase
  test "identical openings in different conversations do not collide" do
    a = MessageNode.append!(conversation: conversation, parent_hash: MessageNode::ROOT, role: "user", content: "hi")
    b = MessageNode.append!(conversation: conversation, parent_hash: MessageNode::ROOT, role: "user", content: "hi")
    refute_equal a.content_hash, b.content_hash
    assert_equal a, MessageNode.append!(conversation: a.conversation, parent_hash: MessageNode::ROOT, role: "user", content: "hi")
  end
end
