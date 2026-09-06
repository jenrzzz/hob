require "test_helper"

class StructuredTest < ActiveSupport::TestCase
  test "parses bare JSON, fenced JSON, and JSON buried in prose" do
    assert_equal({ "a" => 1 }, Gateway::Structured.parse('{"a": 1}'))
    assert_equal({ "a" => 1 }, Gateway::Structured.parse("```json\n{\"a\": 1}\n```"))
    assert_equal({ "a" => 1 }, Gateway::Structured.parse("Sure! Here you go:\n{\"a\": 1}\nHope that helps."))
    assert_equal [ 1, 2 ], Gateway::Structured.parse("[1, 2]")
  end

  test "re-parses stringified JSON in fields, recursively" do
    parsed = Gateway::Structured.parse('{"tags": "[\"a\", \"b\"]", "inner": {"x": "{\"y\": 1}"}, "plain": "[not json"}')
    assert_equal %w[a b], parsed["tags"]
    assert_equal({ "y" => 1 }, parsed["inner"]["x"])
    assert_equal "[not json", parsed["plain"]
  end

  test "raises ParseError on prose or nothing" do
    assert_raises(Gateway::Structured::ParseError) { Gateway::Structured.parse("I would rather not.") }
    assert_raises(Gateway::Structured::ParseError) { Gateway::Structured.parse("") }
  end
end
