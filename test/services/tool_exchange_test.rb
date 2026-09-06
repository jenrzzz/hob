require "test_helper"

class ToolExchangeTest < ActiveSupport::TestCase
  setup do
    @convo = conversation
    @user = MessageNode.append!(conversation: @convo, parent_hash: MessageNode::ROOT, role: "user", content: "weather?")
  end

  def calls_at(parent, *names)
    ToolExchange.append_calls!(
      conversation: @convo, parent_hash: parent,
      calls: names.map { |n| { "id" => "call_#{n}", "name" => n, "arguments" => { "q" => n } } },
      meta: { "model" => "m", "input_tokens" => 3, "output_tokens" => 2 }
    )
  end

  test "calls chain under the parent, self-describing, tokens on the last only" do
    nodes = calls_at(@user.content_hash, "lookup", "fetch")
    assert_equal [ @user.content_hash, nodes.first.content_hash ], nodes.map(&:parent_hash)
    assert_equal %w[tool_call tool_call], nodes.map(&:kind)
    assert_equal({ "id" => "call_lookup", "name" => "lookup", "arguments" => { "q" => "lookup" } }, nodes.first.tool_call)
    assert_nil nodes.first.meta["output_tokens"]
    assert_equal 2, nodes.last.meta["output_tokens"]
    assert_equal "fetch", nodes.last.meta["tool"]
    assert_equal %w[call_lookup call_fetch], ToolExchange.pending_calls(nodes.last).map { |c| c["id"] }
    assert_empty ToolExchange.pending_calls(@user)
  end

  test "results must answer exactly the pending calls, in call order" do
    nodes = calls_at(@user.content_hash, "lookup", "fetch")
    head = nodes.last

    assert_raises(Gateway::Invalid) { ToolExchange.append_results!(conversation: @convo, head: head, results: [ { id: "call_lookup", content: "x" } ]) }
    assert_raises(Gateway::Invalid) { ToolExchange.append_results!(conversation: @convo, head: head, results: [ { id: "call_lookup", content: "x" }, { id: "call_fetch", content: "y" }, { id: "nope", content: "z" } ]) }
    assert_raises(Gateway::Invalid) { ToolExchange.append_results!(conversation: @convo, head: @user, results: [ { id: "call_lookup", content: "x" } ]) }

    results = ToolExchange.append_results!(conversation: @convo, head: head,
                                           results: [ { id: "call_fetch", content: { "temp" => 20 } }, { id: "call_lookup", content: "" } ])
    assert_equal %w[call_lookup call_fetch], results.map { |n| n.meta["tool_call_id"] }
    assert_equal head.content_hash, results.first.parent_hash
    assert_equal "(no output)", results.first.content
    assert_equal '{"temp":20}', results.last.content
    assert_equal %w[user user], results.map(&:role)
    assert_equal %w[tool_result tool_result], results.map(&:kind)
    assert_empty ToolExchange.pending_calls(results.last)
  end

  test "rounds count call/result exchanges, not calls" do
    assert_equal 0, ToolExchange.rounds(nil)
    assert_equal 0, ToolExchange.rounds(@user)
    first = calls_at(@user.content_hash, "a", "b")
    r1 = ToolExchange.append_results!(conversation: @convo, head: first.last, results: [ { id: "call_a", content: "1" }, { id: "call_b", content: "2" } ])
    assert_equal 1, ToolExchange.rounds(r1.last)
    second = calls_at(r1.last.content_hash, "c")
    assert_equal 1, ToolExchange.rounds(second.last)
    r2 = ToolExchange.append_results!(conversation: @convo, head: second.last, results: [ { id: "call_c", content: "3" } ])
    assert_equal 2, ToolExchange.rounds(r2.last)

    messages = Assembly::Transcript.render(r2.last.ancestry.reverse)
    assert_equal %w[user assistant tool tool assistant tool], messages.map { |m| m["role"] }
    assert_equal %w[call_a call_b], messages[1]["tool_calls"].map { |c| c["id"] }
    assert_equal "call_c", messages.last["tool_call_id"]
  end
end
