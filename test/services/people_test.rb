require "test_helper"

# People (PEOPLE.md): the contract itself. People and their handles, the
# append-only log, the loops it derives, the brief, and what realms let a
# request see.
class PeopleTest < ActiveSupport::TestCase
  setup do
    Current.clearance = "personal"
    @muse, = agent("muse", clearance: "personal")
    @by = People::Writer.new(principal: @muse, surface: "muse", request_id: "req-1")
    @me = People::Writer.new(principal: @principal, surface: "claude-code")
  end

  def eugene(**attrs)
    People.create({ "display_name" => "Eugene Fox", "handles" => [ "(555) 000-1111" ], "realm" => "household" }.merge(attrs.stringify_keys), by: @by)
  end

  def record(person, kind, direction, at:, channel: "text", by: @me, **attrs)
    People.record({ "person" => person.id, "kind" => kind, "direction" => direction, "channel" => channel,
                    "at" => at }.merge(attrs.stringify_keys), by: by)
  end

  test "a person is made with normalized handles, found by any way of writing one, and a known handle is refused" do
    person = eugene("names" => [ "Geno" ], "circles" => [ "Biker Gang" ])
    assert_equal [ { "kind" => "phone", "address" => "+15550001111", "opens_loops" => true } ], person.as_json["handles"]
    assert_equal [ "Biker Gang" ], person.as_json["circles"]
    assert_equal person, People.person!("+1 555-000-1111")
    assert_equal person, People.person!("person:#{person.id}")
    assert_equal @muse, person.created_by
    assert_nil person.principal, "an agent's person is the household's unless it says whose"

    error = assert_raises(People::Invalid) { People.create({ "display_name" => "Geno", "handles" => [ "5550001111" ] }, by: @by) }
    assert_match(/already someone else's: if they are one person, ask to merge/, error.message)
  end

  test "a short code or a no-reply address makes a person automated" do
    assert People.create({ "display_name" => "Bank", "handles" => [ "72727" ] }, by: @by).automated
    assert People.create({ "display_name" => "Shop", "handles" => [ "no-reply@shop.example" ] }, by: @by).automated
    refute People.create({ "display_name" => "Ana", "handles" => [ "ana@example.com" ] }, by: @by).automated
  end

  test "an unknown argument is refused, never ignored" do
    error = assert_raises(People::Invalid) { People.list("circles" => "family") }
    assert_match(/unknown filter: circles/, error.message)
  end

  test "an inbound text opens a loop aged from the first message; more messages keep it open; a reply closes it" do
    person = eugene
    first = record(person, "reached_out", "inbound", at: "2026-10-07T18:00:00Z")
    assert_equal 1, first["opened"].size
    loop_id = first["opened"].first["id"]

    again = record(person, "reached_out", "inbound", at: "2026-10-08T18:00:00Z")
    assert_equal [ loop_id ], again["opened"].map { |l| l["id"] }, "one silence, one loop"
    loop = PeopleLoop.find(loop_id)
    assert_equal [ first["event"]["id"], again["event"]["id"] ], [ loop.opened_by_id, loop.latest_event_id ]
    assert_equal Time.iso8601("2026-10-07T18:00:00Z"), loop.opened_at

    travel_to Time.iso8601("2026-10-15T18:00:00Z") do
      listed = People.loops("older_than" => 7)["loops"]
      assert_equal [ [ loop_id, 8, "unanswered_inbound" ] ], listed.map { |l| l.values_at("id", "age_days", "kind") }
    end

    reply = record(person, "replied", "outbound", at: "2026-10-15T19:00:00Z")
    assert_equal [ loop_id ], reply["closed"].map { |l| l["id"] }
    assert_equal [ "closed", reply["event"]["id"] ], PeopleLoop.find(loop_id).values_at(:state, :closed_by_id)
    assert_empty People.loops["loops"]
  end

  test "a reply on another channel does not answer a text; a call answers everything" do
    person = eugene
    record(person, "reached_out", "inbound", at: "2026-10-07T18:00:00Z")
    assert_empty record(person, "replied", "outbound", at: "2026-10-08T18:00:00Z", channel: "email")["closed"]
    assert_equal 1, record(person, "called", "outbound", at: "2026-10-09T18:00:00Z", channel: "call")["closed"].size
  end

  test "a reply seen before the message it would answer does not close it, and a message answered already opens nothing" do
    person = eugene
    record(person, "replied", "outbound", at: "2026-10-09T18:00:00Z")
    late = record(person, "reached_out", "inbound", at: "2026-10-10T18:00:00Z")
    assert_equal 1, late["opened"].size, "the reply came before; this one waits"

    other = People.create({ "display_name" => "Tara", "handles" => [ "+15550002222" ] }, by: @by)
    record(other, "replied", "outbound", at: "2026-10-09T18:00:00Z")
    early = record(other, "reached_out", "inbound", at: "2026-10-08T18:00:00Z")
    assert_empty early["opened"], "read back late, already answered"
  end

  test "dictated loops: owed_action is opened by the event that says so and closed by the one that names it" do
    tara = People.create({ "display_name" => "Tara", "handles" => [ "+15550002222" ] }, by: @by)
    promised = People.record({ "person" => tara.id, "kind" => "met", "direction" => "mutual", "channel" => "in_person",
                               "summary" => "coffee", "loop" => { "kind" => "owed_action", "summary" => "send the ADU photos" } }, by: @me)
    loop = promised["opened"].sole
    assert_equal [ "owed_action", "send the ADU photos", "tester" ], loop.values_at("kind", "summary", "whose")
    assert_equal "dictated", promised["event"]["source"]["kind"]

    sent = People.record({ "person" => tara.id, "kind" => "favor_done", "direction" => "outbound", "summary" => "sent the photos",
                           "closes" => [ loop["id"] ] }, by: @by)
    assert_equal [ loop["id"] ], sent["closed"].map { |l| l["id"] }
    assert_equal "agent", sent["event"]["source"]["kind"]
    error = assert_raises(People::Invalid) { People.record({ "person" => tara.id, "kind" => "note", "closes" => [ loop["id"] ] }, by: @by) }
    assert_match(/closed, not open/, error.message)
  end

  test "an automated person, or a group, never opens a loop" do
    bank = People.create({ "display_name" => "Bank", "handles" => [ "72727" ] }, by: @by)
    assert_empty record(bank, "reached_out", "inbound", at: "2026-10-07T18:00:00Z")["opened"]

    group = PeopleGroup.create!(name: "Scryers", realm: "household")
    result = People.record({ "group" => group.id, "kind" => "reached_out", "direction" => "inbound", "channel" => "text" }, by: @by)
    assert_empty result["opened"]
  end

  test "events are append-only" do
    event = PeopleEvent.find(record(eugene, "reached_out", "inbound", at: "2026-10-07T18:00:00Z")["event"]["id"])
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(summary: "edited") }
  end

  test "snooze hides a loop until then, and a new message wakes it; dismissal is an event and can silence the handle" do
    person = eugene
    loop_id = record(person, "reached_out", "inbound", at: "2026-10-07T18:00:00Z")["opened"].first["id"]
    People.snooze({ "loop" => loop_id, "until" => 2.days.from_now.iso8601 }, by: @by)
    assert_empty People.loops["loops"]
    assert_equal [ loop_id ], People.loops("state" => "snoozed")["loops"].map { |l| l["id"] }

    record(person, "reached_out", "inbound", at: "2026-10-08T18:00:00Z")
    assert_equal [ loop_id ], People.loops["loops"].map { |l| l["id"] }, "a new message is news"
  end

  test "dismissing a loop closes it with an event, and never_again stops its handle opening more" do
    person = Person.create!(display_name: "Eugene", realm: "household")
    handle = person.handles.create!(kind: "phone", address: "+15550001111", realm: "household")
    event = PeopleEvent.create!(person: person, at: 1.day.ago, kind: "reached_out", direction: "inbound", channel: "text",
                                source_kind: "text", source_ref: "m:1", recorded_by: @principal, realm: "household")
    loop = People::Loops.apply!(event, handle: handle)[:opened].sole

    result = People.dismiss({ "loop" => loop.id, "reason" => "a sign-off, not a question", "never_again" => true }, by: @me)
    assert_equal [ "dismissed", true ], [ result["loop"]["state"], result["never_again"] ]
    assert_equal [ "dismissed", "loop:#{loop.id}" ], PeopleEvent.where(kind: "dismissed").sole.values_at(:kind, :source_ref)
    refute handle.reload.opens_loops

    again = PeopleEvent.create!(person: person, at: Time.current, kind: "reached_out", direction: "inbound", channel: "text",
                                source_kind: "text", source_ref: "m:2", recorded_by: @principal, realm: "household")
    assert_empty People::Loops.apply!(again, handle: handle)[:opened]
  end

  test "the brief: who, circles and the people in them, contact both ways, open loops, recent events, notes" do
    person = eugene("circles" => [ "Biker Gang" ], "key_dates" => [ { "kind" => "birthday", "date" => "--10-20" } ])
    People.create({ "display_name" => "Jarret", "circles" => [ "biker gang" ] }, by: @by)
    record(person, "replied", "outbound", at: "2024-09-01T18:00:00Z")
    record(person, "reached_out", "inbound", at: "2026-10-07T18:00:00Z")
    People.note({ "person" => person.id, "body" => "Festival crew; moved away in 2023. Ask about the new place." }, by: @by)

    travel_to Time.iso8601("2026-10-15T18:00:00Z") do
      brief = People.get("person" => "+15550001111")
      assert_equal "Eugene Fox", brief.dig("person", "display_name")
      assert_equal [ "Jarret" ], brief["mutual"].map { |p| p["display_name"] }, "circle names match without regard to case"
      assert_equal [ "Biker Gang" ], brief["groups"].map { |g| g["name"] }
      assert_equal [ "2026-10-07T18:00:00Z", "2024-09-01T18:00:00Z" ], brief["contact"].values_at("last_inbound_at", "last_outbound_at")
      assert_equal [ [ "unanswered_inbound", 8 ] ], brief["open_loops"].map { |l| l.values_at("kind", "age_days") }
      assert_equal %w[reached_out replied], brief["recent_events"].map { |e| e["kind"] }
      assert_equal [ "muse" ], brief["notes"].map { |n| n.dig("by", "principal") }
      assert_equal [ { "kind" => "birthday", "date" => "--10-20", "next" => "2026-10-20", "in_days" => 5 } ], brief["upcoming_dates"]
      assert brief["notice"]
    end
  end

  test "quiet is judged against the relationship's own rhythm, or the cadence a person set" do
    sister = People.create({ "display_name" => "Sister", "handles" => [ "+15550003333" ] }, by: @by)
    friend = People.create({ "display_name" => "Yearly", "handles" => [ "+15550004444" ] }, by: @by)
    (1..10).each { |day| record(sister, "reached_out", day.odd? ? "inbound" : "outbound", at: "2026-10-#{format('%02d', day)}T18:00:00Z") }
    record(friend, "reached_out", "inbound", at: "2026-10-02T18:00:00Z")

    travel_to Time.iso8601("2026-10-15T18:00:00Z") do
      assert_equal [ "Sister" ], People.list("quiet" => true)["people"].map { |p| p["display_name"] },
                   "five days is loud for daily, and a single message is no rhythm at all"
      People.update({ "person" => friend.id, "cadence_days" => 3 }, by: @by)
      assert_equal %w[Sister Yearly], People.list("quiet" => true)["people"].map { |p| p["display_name"] }
    end
  end

  test "list filters: circle, open loops, upcoming dates, q over names and handles" do
    person = eugene("circles" => [ "family" ], "key_dates" => [ { "kind" => "birthday", "date" => "1990-10-20" } ])
    People.create({ "display_name" => "Tara", "names" => [ "T-bone" ], "handles" => [ "tara@example.com" ] }, by: @by)
    record(person, "reached_out", "inbound", at: "2026-10-07T18:00:00Z")

    travel_to Time.iso8601("2026-10-15T18:00:00Z") do
      assert_equal [ "Eugene Fox" ], People.list("circle" => "Family")["people"].map { |p| p["display_name"] }
      assert_equal [ "Eugene Fox" ], People.list("has_open_loops" => true)["people"].map { |p| p["display_name"] }
      assert_equal [ "Tara" ], People.list("has_open_loops" => false)["people"].map { |p| p["display_name"] }
      assert_equal [ "Eugene Fox" ], People.list("upcoming" => 7)["people"].map { |p| p["display_name"] }
      assert_equal [ "Tara" ], People.list("q" => "bone")["people"].map { |p| p["display_name"] }
      assert_equal [ "Tara" ], People.list("q" => "tara@")["people"].map { |p| p["display_name"] }
    end
  end

  test "update changes circles as a set, or by adding and removing" do
    person = eugene("circles" => [ "family", "biker gang" ])
    assert_equal [ "biker gang" ], People.update({ "person" => person.id, "remove_circles" => [ "Family" ] }, by: @by).groups.map(&:name)
    assert_equal [ "biker gang", "scryers" ], People.update({ "person" => person.id, "add_circles" => [ "scryers" ] }, by: @by).groups.map(&:name).sort
    assert_equal [ "family" ], People.update({ "person" => person.id, "circles" => [ "family" ] }, by: @by).groups.map(&:name)
  end

  test "a merge makes two records one: handles, circles, and loops move; events stay as written and are read together" do
    old = eugene("circles" => [ "family" ])
    new_number = People.create({ "display_name" => "Eugene (new number)", "handles" => [ "+15559990000" ], "realm" => "household" }, by: @by)
    record(old, "reached_out", "inbound", at: "2026-10-01T18:00:00Z")
    record(new_number, "reached_out", "inbound", at: "2026-10-07T18:00:00Z")
    old_event = PeopleEvent.where(person: old).sole

    result = People.merge({ "into" => old.id, "from" => new_number.id, "reason" => "same person" }, by: @me)
    assert_equal new_number.id, result["merged"]
    assert_equal %w[+15550001111 +15559990000], old.reload.handles.map(&:address).sort
    assert_includes old.names, "Eugene (new number)"
    assert_equal old, People.person!("+15559990000"), "the merged record answers as the one it became"
    assert_equal old, People.person!(new_number.id)
    assert_equal old.id, old_event.reload.person_id
    assert_equal new_number.id, PeopleEvent.where(person_id: new_number.id).sole.person_id, "events are not rewritten"

    brief = People.get("person" => old.id)
    assert_equal 2, brief["recent_events"].size
    assert_equal [ new_number.id ], brief["merged_from"]
    assert_equal [ Time.iso8601("2026-10-01T18:00:00Z") ], PeopleLoop.outstanding.map(&:opened_at), "two silences became one, aged from the first"
    assert_equal 1, record(old, "replied", "outbound", at: "2026-10-08T18:00:00Z")["closed"].size
  end

  test "a merge into a lower realm is refused: it would show what the higher one held" do
    household = eugene
    personal = People.create({ "display_name" => "Eugene", "handles" => [ "+15559990000" ], "realm" => "personal" }, by: @by)
    error = assert_raises(People::Invalid) { People.merge({ "into" => household.id, "from" => personal.id }, by: @me) }
    assert_match(/merge into the personal one/, error.message)
  end

  test "realms: a household request sees a household person but not a personal event, loop, or note about them" do
    person = eugene
    record(person, "reached_out", "inbound", at: "2026-10-07T18:00:00Z", realm: "personal")
    People.note({ "person" => person.id, "body" => "Jenner's college friend", "realm" => "personal" }, by: @by)
    as(@muse, realm: "personal") do
      note = People.note({ "person" => person.id, "body" => "Rides with the gang" }, by: @by)
      assert_equal "personal", note.dig("note", "realm"), "a note defaults to the caller's clearance"
    end

    household, = agent("tessa-agent", clearance: "household")
    as(household, realm: "household") do
      brief = People.get("person" => person.id)
      assert_empty brief["recent_events"]
      assert_empty brief["open_loops"]
      assert_empty brief["notes"]
      assert_empty People.loops["loops"]
    end

    secret = People.create({ "display_name" => "Someone", "handles" => [ "+15558887777" ], "realm" => "personal" }, by: @by)
    as(household, realm: "household") do
      assert_raises(People::NotFound) { People.get("person" => secret.id) }
      assert_raises(People::NotFound) { People.get("person" => "+15558887777") }
      error = assert_raises(People::Invalid) { People.record({ "person" => person.id, "kind" => "note", "realm" => "personal" }, by: @by) }
      assert_match(/above this request's clearance/, error.message)
    end
  end

  test "nothing is written about a person below their own realm" do
    secret = People.create({ "display_name" => "Someone", "handles" => [ "+15558887777" ], "realm" => "personal" }, by: @by)
    error = assert_raises(People::Invalid) { People.note({ "person" => secret.id, "body" => "x", "realm" => "household" }, by: @by) }
    assert_match(/below personal/, error.message)
  end

  test "key dates are checked: a date, or a month and day that recurs" do
    error = assert_raises(People::Invalid) { eugene("key_dates" => [ { "kind" => "birthday", "date" => "October 20" } ]) }
    assert_match(/YYYY-MM-DD, or --MM-DD/, error.message)
    leap = eugene("key_dates" => [ { "kind" => "birthday", "date" => "2000-02-29" } ])
    assert_equal "2027-02-28", leap.upcoming_dates(Date.new(2026, 10, 15)).first["next"]
  end
end
