require "test_helper"

# Where every clip sits: the shape of a show, with no sound made.
class CastsTimelineTest < ActiveSupport::TestCase
  def take(name, seconds, first: "a", last: "b", beat: false)
    { clip: name, duration: seconds, first: first, last: last, beat: beat }
  end

  def parts
    [ { "kind" => "cold_open", "takes" => [ take("cold", 5.0) ] },
      { "kind" => "segment", "takes" => [ take("s1a", 30.0), take("s1b", 20.0, first: "a") ] },
      { "kind" => "segment", "takes" => [ take("s2", 25.0) ] },
      { "kind" => "segment", "takes" => [ take("s3", 25.0) ] },
      { "kind" => "sign_off", "takes" => [ take("bye", 6.0) ] } ]
  end

  def at(timeline, clip) = timeline[:placements].select { |p| p[:clip] == clip }

  test "cold open, theme, segments with stings between, and the theme out" do
    timeline = Casts::Timeline.new(parts: parts, theme: { clip: "theme", duration: 40.0 },
                                   stingers: [ { clip: "st0", duration: 2.5 }, { clip: "st1", duration: 2.0 } ]).call
    cold, s1a, s1b, s2, s3, bye = %w[cold s1a s1b s2 s3 bye].map { |c| at(timeline, c).sole }
    intro, outro = at(timeline, "theme")

    assert_in_delta 0.3, cold[:at]
    assert_in_delta 5.55, intro[:at], 0.001, "the theme lands just after the cold open"
    assert_equal 0.8, intro[:envelope].first.last
    assert_in_delta intro[:at] + 6.0, s1a[:at], 0.001, "and plays alone before the welcome"
    assert_equal 0.13, intro[:envelope][2].last, "then sits under it"
    assert_equal 0.0, intro[:envelope].last.last
    assert_in_delta 22.0, intro[:length]

    gap = s1b[:at] - (s1a[:at] + 30.0)
    assert gap.between?(0.14, 0.30), "takes inside a segment trade as turns (#{gap})"

    st0 = at(timeline, "st0").sole
    assert_in_delta s1b[:at] + 20.0 + 0.35, st0[:at], 0.001
    assert_in_delta st0[:at] + 2.35, s2[:at], 0.001, "the next segment starts as the sting rings out"
    assert_operator at(timeline, "st1").sole[:at], :<, s3[:at]

    assert_in_delta outro[:at] + 1.0, bye[:at], 0.001, "the theme arrives before the sign-off"
    assert_equal 0.0, outro[:envelope].first.last
    assert_in_delta 40.0, outro[:offset] + outro[:length], 0.001, "and is cut to end on its own ending"
    spoken = bye[:at] + 6.0 - outro[:at]
    assert_equal [ spoken.round(3), 0.13 ], outro[:envelope][2].map { |v| v.round(3) }
    assert_equal 0.8, outro[:envelope][3].last, "swelling once they stop"
    assert_in_delta outro[:at] + outro[:length] + 0.4, timeline[:duration], 0.001
    assert timeline[:placements].each_cons(2).all? { |x, y| x[:at] <= y[:at] }
    assert_equal %i[voice bed], [ cold[:bus], intro[:bus] ]
  end

  test "with no dressing it is the voices and plain pauses" do
    timeline = Casts::Timeline.new(parts: parts).call
    assert timeline[:placements].all? { |p| p[:bus] == :voice }
    s1b, s2 = at(timeline, "s1b").sole, at(timeline, "s2").sole
    assert_in_delta 0.9, s2[:at] - (s1b[:at] + 20.0), 0.001
  end

  test "a beat is held between takes" do
    held = [ { "kind" => "segment", "takes" => [ take("one", 4.0, beat: true), take("two", 4.0) ] } ]
    timeline = Casts::Timeline.new(parts: held).call
    assert_in_delta Casts::Pacer::BEAT, at(timeline, "two").sole[:at] - (at(timeline, "one").sole[:at] + 4.0), 0.001
  end

  test "a theme shorter than the ending comes in late rather than running out" do
    long = [ { "kind" => "segment", "takes" => [ take("s", 10.0) ] }, { "kind" => "sign_off", "takes" => [ take("bye", 30.0) ] } ]
    timeline = Casts::Timeline.new(parts: long, theme: { clip: "theme", duration: 20.0 }).call
    outro = at(timeline, "theme").last
    bye = at(timeline, "bye").sole
    assert_in_delta 20.0, outro[:length]
    assert_equal 0.0, outro[:offset]
    assert_operator outro[:at], :>, bye[:at]
    assert_operator outro[:at] + outro[:length], :>, bye[:at] + 30.0
  end
end
