require_relative "test_helper"

class FakeTest < Minitest::Test
  def setup
    @hob = Hob::Fake.new
  end

  def test_scripted_completions_record_calls_and_parse
    @hob.reply('{"title":"Soup"}')
    completion = @hob.complete(role: "extractor", messages: [ { role: "user", content: "soup" } ], schema: { type: "object" })
    assert_equal({ "title" => "Soup" }, completion.parsed)
    assert_equal :complete, @hob.calls.last.kind
    assert_equal "extractor", @hob.calls.last.args[:role]
    assert_equal %w[user assistant], @hob.conversations.show(completion.id).messages.map { |m| m["role"] }
    assert_equal "success", @hob.completion(completion.id).status
  end

  def test_refusals_failures_and_exhaustion
    @hob.refuse
    assert_raises(Hob::Refused) { @hob.complete(role: "x", messages: []) }
    @hob.fail(Hob::Unavailable.new("down"))
    assert_raises(Hob::Unavailable) { @hob.complete(role: "x", messages: []) }
    assert_raises(Hob::Error) { @hob.complete(role: "x", messages: []) }
  end

  def test_tool_loop_through_the_fake
    @hob.call_tool("lookup", { q: "bees" }, id: "call_1").reply("Bees are fine.")
    first = @hob.complete(role: "extractor", messages: [ { role: "user", content: "bees?" } ], tools: [])
    assert first.tool_calls?
    second = @hob.complete(id: first.id, tool_results: [ first.tool_calls.first.result("ok") ])
    assert_equal "Bees are fine.", second.content
    assert_equal first.id, second.id
    assert_equal %w[text tool_call tool_result text], @hob.conversations.show(first.id).messages.map { |m| m["kind"] || "text" }
  end

  def test_chat_streams_and_keeps_a_transcript
    convo = @hob.conversations.create(title: "Dinner")
    @hob.reply("Soup tonight.")
    deltas = []
    turn = @hob.chat(conversation: convo, content: "dinner?", persona: "saffron") { |e| deltas << e.content if e.delta? }
    assert_equal "Soup tonight.", deltas.join
    assert_equal "Soup tonight.", turn.content
    @hob.conversations.event(convo.id, content: "Added soup")
    assert_equal %w[user assistant event], @hob.conversations.show(convo.id).messages.map { |m| m["role"] }
    assert_equal "saffron", @hob.calls.last.args[:persona]
  end
end
