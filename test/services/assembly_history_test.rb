require "test_helper"

# The history stage's budget never cuts a tool exchange in half, and earlier
# turns' tool results are shortened (MELUZINA.md, "The Discord bridge").
class AssemblyHistoryTest < ActiveSupport::TestCase
  setup do
    @convo = conversation(realm: "personal")
    @head = nil
  end

  def say(role, content, kind: "text", meta: {})
    @head = MessageNode.append!(conversation: @convo, parent_hash: @head&.content_hash, role: role, content: content,
                                kind: kind, meta: meta)
  end

  def search_round(id, result)
    say("assistant", JSON.generate("id" => id, "name" => "recall_archive", "arguments" => { "query" => "heilung" }),
        kind: "tool_call", meta: { "tool_call_id" => id, "stop_reason" => "tool_use" })
    say("user", result, kind: "tool_result", meta: { "tool_call_id" => id })
  end

  def history(budget)
    preset = Preset.create!(key: "h#{budget}", name: "H", stages: [ { "name" => "history", "enabled" => true, "budget" => budget } ])
    Assembly::Pipeline.new(conversation: @convo, head: @head, preset: preset).assemble.messages
  end

  test "the turn in progress is kept whole, however much its tool rounds cost" do
    say("user", "earlier line")
    say("assistant", "earlier reply")
    say("user", "remember heilung?")
    search_round("t1", "x" * 20_000)
    search_round("t2", "y" * 20_000)

    messages = history(1_000)
    assert_equal "remember heilung?", messages.first["content"]
    assert_equal %w[user assistant tool assistant tool], messages.map { |m| m["role"] }
    assert_equal 20_000, messages.last["content"].length, "the current turn's results are not shortened"
  end

  test "older turns start at a spoken line and their tool results are shortened" do
    say("user", "f" * 8_000)
    say("assistant", "hi")
    say("user", "remember heilung?")
    search_round("t1", "z" * 5_000)
    say("assistant", "you said, march 2021: heilung live would fix me")
    say("user", "yes that")

    messages = history(100_000)
    assert_equal "f" * 8_000, messages.first["content"]
    shortened = messages.find { |m| m["role"] == "tool" }["content"]
    assert_operator shortened.length, :<, 500
    assert_match(/5000 characters; used in an earlier reply/, shortened)

    tight = history(1_200)
    assert_equal "remember heilung?", tight.first["content"], "the cut lands where he spoke, not on the tool result"
    assert_equal "yes that", tight.last["content"]
  end

  test "a conversation that fits keeps its opening greeting" do
    say("assistant", "rar")
    say("user", "meow")
    assert_equal %w[rar meow], history(8_000).map { |m| m["content"] }
  end
end
