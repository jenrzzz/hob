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

class ModelPriceSetTest < ActiveSupport::TestCase
  test "set! upserts with default cache multipliers and reprices the ledger it now covers" do
    UsageEvent.record(surface: "muse", role: "sentinel-steward", model: "claude-opus-5", status: "success",
                      units: { "input_tokens" => 1_000_000, "output_tokens" => 100_000 })
    UsageEvent.record(surface: "muse", role: "sentinel-steward", model: "claude-opus-5", status: "error", units: {})
    UsageEvent.record(surface: "t", role: "chat-default", model: "claude-sonnet-5", status: "success", units: { "input_tokens" => 1_000_000 })
    assert_nil UsageEvent.where(model: "claude-opus-5").first.cost
    assert_equal [ "claude-opus-5" ], ModelPrice.unpriced_models

    row = ModelPrice.set!(model: "claude-opus-5", input: 5, output: 25, note: "Anthropic list", effective_from: "2026-06-01")
    assert row.previously_new_record?
    assert_equal 0.5, row.cache_read.to_f
    assert_equal 6.25, row.cache_write.to_f
    assert_equal 1, row.repriced
    assert_equal 7.5, UsageEvent.successful.find_by(model: "claude-opus-5").cost.to_f
    assert_nil UsageEvent.find_by(model: "claude-opus-5", status: "error").cost, "failed calls stay unpriced"
    assert_empty ModelPrice.unpriced_models
    assert_equal "Anthropic list", row.note
    assert_equal Date.new(2026, 6, 1), row.effective_from

    # A correction reprices what changed; an explicit cache rate is kept.
    again = ModelPrice.set!(model: "claude-opus-5", input: 4, output: 20, cache_read: 0.3)
    assert_not again.previously_new_record?
    assert_equal 0.3, again.cache_read.to_f
    assert_equal 5.0, again.cache_write.to_f
    assert_equal 1, again.repriced
    assert_equal 6.0, UsageEvent.successful.find_by(model: "claude-opus-5").cost.to_f
    assert_equal 0, ModelPrice.set!(model: "claude-opus-5", input: 4, output: 20, cache_read: 0.3).repriced

    # A more specific row takes its dated ids away from the family row.
    UsageEvent.record(surface: "t", role: "x", model: "claude-opus-5-20260901", status: "success", units: { "input_tokens" => 1_000_000 })
    assert_equal 4.0, UsageEvent.find_by(model: "claude-opus-5-20260901").cost.to_f
    dated = ModelPrice.set!(model: "claude-opus-5-20260901", input: 1, output: 2)
    assert_equal 1, dated.repriced
    assert_equal 1.0, UsageEvent.find_by(model: "claude-opus-5-20260901").cost.to_f
    assert_equal 0, ModelPrice.set!(model: "claude-opus-5", input: 4, output: 20, cache_read: 0.3).repriced, "the family row leaves the dated id alone"

    assert_raises(ActiveRecord::RecordInvalid) { ModelPrice.set!(model: "not a model", input: 1, output: 1) }
    assert_raises(ActiveRecord::RecordInvalid) { ModelPrice.set!(model: "x-1", input: -1, output: 1) }
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
