require "test_helper"

# What the hosts say: tidied, budgeted, and cut into takes.
class CastsScriptTest < ActiveSupport::TestCase
  setup { @cast = cast! }

  def line(speaker, text, **more) = { "speaker" => speaker, "text" => text }.merge(more.stringify_keys)

  test "a written script is made sayable and keeps its directions" do
    script = Casts::Script.tidy({
      "title" => "Rates hold", "summary" => "The Fed waits.",
      "cold_open" => [ line("a", "[deadpan] So that **happened**.") ],
      "segments" => [
        { "headline" => "Rates", "lines" => [
          line("b", "According to [the Times](https://nytimes.com/a_(b)), it held. See https://example.com/x for more."),
          line("nobody", "[laughs] Sure."), line("a", "   "), line("a", "Hm.", beat: true)
        ] },
        { "headline" => "Empty", "lines" => [] }
      ],
      "sign_off" => [ line("a", "That's the show.") ]
    }, @cast)

    assert_equal "[deadpan] So that happened.", script["cold_open"].sole["text"]
    said = script["segments"].sole["lines"]
    assert_equal "According to the Times, it held. See for more.", said[0]["text"]
    assert_equal "a", said[1]["speaker"], "a speaker who is not a host becomes the first host"
    assert_equal "[laughs] Sure.", said[1]["text"]
    assert_equal [ "Hm.", true ], said[2].values_at("text", "beat")
    assert_equal 3, said.size
  end

  test "segments past the budget are dropped from the end, never the last one" do
    @cast.update!(config: { "max_characters" => 500 })
    segment = ->(n) { { "headline" => "S#{n}", "lines" => [ line("a", "x" * 300) ] } }
    script = Casts::Script.tidy({ "segments" => [ segment.(1), segment.(2), segment.(3) ] }, @cast)
    assert_equal %w[S1], script["segments"].map { |s| s["headline"] }
    assert_equal 2, script["dropped_segments"]

    assert_raises(Gateway::Refused) { Casts::Script.tidy({ "segments" => [] }, @cast) }
  end

  test "lines are cut into takes at the limit and after a beat" do
    lines = [ line("a", "a" * 900), line("b", "b" * 800), line("a", "c" * 200), line("b", "Oh.", beat: true), line("a", "Anyway.") ]
    takes = Casts::Script.takes(lines, @cast)

    assert_equal [ 2, 2, 1 ], takes.map { |t| t["lines"].size }
    assert_equal [ %w[a b], %w[a b], %w[a a] ], takes.map { |t| t.values_at("first", "last") }
    assert_equal [ nil, true, nil ], takes.map { |t| t["beat"] }
    assert_equal "JBFqnCBsd6RMkjVDRZzb", takes[0]["lines"][0]["voice_id"]
    assert_equal "EXAVITQu4vr4xnSDxMaL", takes[0]["lines"][1]["voice_id"]
    assert takes.all? { |t| t["lines"].sum { |l| l["text"].length } <= Voice::DIALOGUE_MAX_CHARACTERS }
  end

  test "voicing by lines makes every line its own take" do
    @cast.update!(config: { "voicing" => "lines" })
    takes = Casts::Script.takes([ line("a", "One."), line("b", "Two."), line("b", "Three.") ], @cast)
    assert_equal [ 1, 1, 1 ], takes.map { |t| t["lines"].size }
  end

  test "a line too long for a take is split at its sentences" do
    text = Array.new(40) { |i| "Sentence number #{i} goes on for a little while longer than it should." }.join(" ")
    takes = Casts::Script.takes([ line("a", text, beat: true) ], @cast)
    assert_operator takes.size, :>, 1
    assert_equal text, takes.flat_map { |t| t["lines"].map { |l| l["text"] } }.join(" ")
    assert_equal [ true ], takes.map { |t| t["beat"] }.compact, "the beat follows the last piece"
    assert_equal true, takes.last["beat"]
  end

  test "the pacer tells a turn from a carried-on thought from a beat" do
    pacer = Casts::Pacer.new("episode")
    turns = Array.new(50) { pacer.gap("a", "b") }
    same = Array.new(50) { pacer.gap("a", "a") }

    assert turns.all? { |g| g.between?(0.14, 0.30) }
    assert same.all? { |g| g.between?(0.37, 0.53) }
    assert_operator turns.uniq.size, :>, 10, "jittered, so a run of turns doesn't tick"
    assert_equal Casts::Pacer::BEAT, pacer.gap("a", "b", beat: true)
    assert_equal Array.new(5) { Casts::Pacer.new("x").gap("a", "b") }.uniq.size, 1, "the same episode paces the same"
  end

  test "a cast's config is checked" do
    assert_not Cast.new(slug: "x", title: "X", realm: "personal", config: { "voicing" => "sung" }).valid?
    assert_not Cast.new(slug: "x", title: "X", realm: "personal", config: { "tempo" => 3 }).valid?
    assert_not Cast.new(slug: "x", title: "X", realm: "personal", config: { "hosts" => [ { "key" => "a", "name" => "A" } ] }).valid?
    assert_not Cast.new(slug: "Bad Slug", title: "X", realm: "personal").valid?
  end
end
