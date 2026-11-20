require "test_helper"

class AssemblyClockTest < ActiveSupport::TestCase
  CLOCK = {
    "zones" => [ { "label" => "her", "zone" => "America/Chicago" },
                 { "label" => "him", "zone" => "America/Los_Angeles", "reader" => true } ],
    "drift_gap_minutes" => 20,
    "visit_gap_hours" => 6,
    "calendar" => [ { "month" => 7, "day" => 28, "label" => "Transformation Day" },
                    { "month" => 1, "day" => 1, "label" => "far off" } ]
  }.freeze

  setup do
    @persona = persona("robyn")
    @persona.update!(clock: CLOCK)
    @convo = conversation
  end

  # Appends a chain of [role, content, time, meta] and returns the last node.
  def chain(*lines)
    parent = MessageNode::ROOT
    lines.map do |role, content, at, meta|
      travel_to(at) do
        node = MessageNode.append!(conversation: @convo, parent_hash: parent, role: role, content: content, meta: meta || {})
        parent = node.content_hash
        node
      end
    end.last
  end

  def assemble(head, at:, **opts)
    travel_to(at) do
      Assembly::Pipeline.new(conversation: @convo, head: head, personas: [ @persona ], **opts).assemble
    end
  end

  def pacific(text) = ActiveSupport::TimeZone["America/Los_Angeles"].parse(text)

  test "a gap marks the later user line, on the reader's clock, in the assembled copy only" do
    head = chain(
      [ "user", "rar", pacific("2026-07-20 22:00") ],
      [ "assistant", "meow", pacific("2026-07-20 22:01") ],
      [ "user", "back", pacific("2026-07-20 23:30") ],
      [ "assistant", "o.o", pacific("2026-07-20 23:31") ],
      [ "user", "next day", pacific("2026-07-21 01:05") ]
    )
    result = assemble(head, at: pacific("2026-07-21 01:06"))
    users = result.messages.select { |m| m["role"] == "user" }

    assert_equal "rar", users[0]["content"]
    assert_equal "[time drifts — it's 11:30pm for him now]\n\nback", users[1]["content"]
    assert_equal "[time drifts — it's Tuesday now, 1:05am for him]\n\nnext day", users[2]["content"]
    assert_equal "back", @convo.message_nodes.find_by(content: "back").content
    assert_equal 2, result.snapshot.assembled["stages"].find { |s| s["name"] == "history" }["drifts"]
  end

  test "a whisper does not reset the gap" do
    head = chain(
      [ "user", "*goodnight*", pacific("2026-07-20 23:00") ],
      [ "assistant", "nyt!", pacific("2026-07-20 23:01") ],
      [ "assistant", "misha knocked the tower over", pacific("2026-07-21 15:00"), { "whisper" => true } ],
      [ "user", "lol", pacific("2026-07-21 15:10") ]
    )
    result = assemble(head, at: pacific("2026-07-21 15:11"))
    assert_match(/\A\[time drifts — it's Tuesday now, 3:10pm for him\]/, result.messages.select { |m| m["role"] == "user" && m["hash"] }.last["content"])
  end

  test "the clock stage follows history and names the zones, the last visit, and near dates" do
    head = chain(
      [ "user", "rar", pacific("2026-07-20 22:00") ],
      [ "assistant", "meow", pacific("2026-07-20 22:01") ],
      [ "user", "*settles in by the hearth*", pacific("2026-07-26 21:00") ]
    )
    result = assemble(head, at: pacific("2026-07-26 21:00"))
    names = result.snapshot.assembled["stages"].map { |s| s["name"] }
    assert_equal names.index("history") + 1, names.index("clock")

    now = result.messages.last["content"]
    assert_includes now, "## Right now"
    assert_includes now, "For her: Sunday July 26, 11:00pm."
    assert_includes now, "For him: Sunday July 26, 9:00pm."
    assert_includes now, "The last lines above were 6 days ago (July 20)"
    assert_includes now, "Calendar: in 2 days: Transformation Day"
    refute_includes now, "far off"
    refute_includes result.system, "Right now"
  end

  test "a short gap says nothing about a last visit" do
    head = chain([ "user", "rar", pacific("2026-07-20 22:00") ], [ "user", "hi", pacific("2026-07-20 23:00") ])
    refute_includes assemble(head, at: pacific("2026-07-20 23:00")).messages.last["content"], "last lines"
  end

  test "a persona without a clock is untouched, and a preset without the stage gets it" do
    plain = persona("plain")
    head = chain([ "user", "a", pacific("2026-07-20 10:00") ], [ "user", "b", pacific("2026-07-20 15:00") ])
    result = travel_to(pacific("2026-07-20 15:00")) do
      Assembly::Pipeline.new(conversation: @convo, head: head, personas: [ plain ]).assemble
    end
    assert_equal %w[a b], result.messages.map { |m| m["content"] }
    assert_nil result.snapshot.assembled["stages"].find { |s| s["name"] == "clock" }

    preset = Preset.create!(key: "old", name: "Old", stages: [ { "name" => "history", "enabled" => true, "budget" => 8_000 } ])
    names = assemble(head, at: pacific("2026-07-20 15:00"), preset: preset).snapshot.assembled["stages"].map { |s| s["name"] }
    assert_equal %w[history clock], names
  end

  test "a bad clock is refused" do
    assert_not @persona.update(clock: { "zones" => [ { "zone" => "Mars/Olympus" } ] })
    assert_match(/unknown time zone/, @persona.errors[:clock].first)
    assert_not @persona.update(clock: { "zones" => [], "drift_gap_minutes" => 5 })
    assert_not @persona.update(clock: CLOCK.merge("calendar" => [ { "month" => 2, "day" => 31 } ]))
    assert @persona.update(clock: {})
  end

  test "February 29 lands on the 28th in a common year" do
    clock = Assembly::Clock.new(CLOCK.merge("calendar" => [ { "month" => 2, "day" => 29, "label" => "leap" } ]))
    assert_equal [ "in 1 day: leap" ], clock.calendar_notes(pacific("2027-02-27 12:00"))
  end
end
