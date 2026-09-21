require "test_helper"

# hob.calendar.push (SENTINEL.md): skipsy and marley pushing normalized
# events into the household calendar mirror, each for the person they are
# registered to push for, free/busy unless the push says otherwise.
class CalendarPushTest < ActiveSupport::TestCase
  setup do
    native_capabilities!
    @skipsy, _ = agent("skipsy")
    @marley, _ = agent("marley")
    @jenner = @principal
    @tessa = Principal.create!(name: "tessa", kind: "human", max_clearance: "intimate")
    CalendarContributor.create!(owner: @jenner, agent: @skipsy)
    CalendarContributor.create!(owner: @tessa, agent: @marley)
    policy!(nil, "hob.calendar.push", "allow")
  end

  def push(arguments, agent: @skipsy)
    as(agent, realm: "household") do
      Sentinel.submit!(agent: agent, capability: "hob.calendar.push", arguments: arguments, reason: "sync")
    end
  end

  def event(uid, start: "2026-10-05T09:00:00-07:00", finish: "2026-10-05T10:00:00-07:00", **rest)
    { "uid" => uid, "start" => start, "end" => finish }.merge(rest.stringify_keys)
  end

  # Runs the block with every way of opening a TCP connection replaced by
  # one that records the attempt and raises. -> the attempts
  def without_network
    attempts = []
    doors = [ [ TCPSocket, :new ], [ TCPSocket, :open ], [ Socket, :tcp ] ]
    originals = doors.map { |klass, name| klass.method(name) }
    doors.each do |klass, name|
      klass.define_singleton_method(name) { |*args, **| attempts << [ klass, name, args ]; raise "hob.calendar.push opened a connection" }
    end
    yield
    attempts
  ensure
    doors.zip(originals) { |(klass, name), original| klass.define_singleton_method(name, original) }
  end

  def push!(events, owner: "tester", agent: @skipsy, **rest)
    push({ "owner" => owner, "events" => events }.merge(rest.stringify_keys), agent: agent).tap do |request|
      assert_equal "completed", request.status, request.error.to_s
    end
  end

  test "sync! registers the capability as a native act at household" do
    cap = Capability.find_by!(name: "hob.calendar.push")
    assert cap.native?
    assert_equal Sentinel::Native::CalendarPush, cap.handler
    assert_equal "calendar_push", cap.config["handler"]
    assert_equal "act", cap.kind
    assert_equal "household", cap.realm
    assert_equal %w[owner events], cap.input_schema["required"]
    assert_equal %w[free_busy details], cap.input_schema["properties"]["visibility"]["enum"]
  end

  # 1. A push by an agent registered for the named owner stores events and returns accurate stored/updated counts.
  test "a push by a registered agent stores the events and counts them" do
    request = push!([ event("a"), event("b", start: "2026-10-06T00:00:00-07:00", finish: "2026-10-07T00:00:00-07:00", all_day: true),
                      event("c", busy: false, status: "tentative") ], calendar: "work")
    assert_equal({ "owner" => "tester", "calendar" => "work", "visibility" => "free_busy", "stored" => 3, "updated" => 0,
                   "removed" => 0, "rejected" => [], "notice" => "titles dropped: visibility is free_busy" }, request.result)

    assert_equal 3, CalendarEvent.count
    a = CalendarEvent.find_by!(uid: "a")
    assert_equal [ @skipsy, @jenner, "work", "free_busy" ], [ a.source_agent, a.owner, a.calendar, a.visibility ]
    assert_equal Time.utc(2026, 10, 5, 16), a.start_at, "stored as the instant the offset named"
    assert_equal Time.utc(2026, 10, 5, 17), a.end_at
    assert_equal [ false, true, nil ], [ a.all_day, a.busy, a.status ], "all_day defaults false, busy true"
    assert CalendarEvent.find_by!(uid: "b").all_day
    c = CalendarEvent.find_by!(uid: "c")
    assert_equal [ false, "tentative" ], [ c.busy, c.status ]

    # No calendar label is the unnamed calendar, and an empty batch is fine.
    unnamed = push!([ event("a") ])
    assert_equal [ "", 1, 0 ], unnamed.result.values_at("calendar", "stored", "updated"), "a different calendar, so a different event"
    assert_equal 0, push!([]).result["stored"]
  end

  # 2. A push naming an owner the calling agent is not registered for is rejected with no writes.
  test "a push for an owner the agent is not registered for is refused and writes nothing" do
    Principal.create!(name: "mise-worker", kind: "worker", max_clearance: "household")

    {
      "tessa" => /skipsy is not a registered contributor for tessa's calendar/,
      "nobody" => /nobody is not a known household member/,
      "marley" => /marley is not a known household member/,
      "mise-worker" => /mise-worker is not a known household member/
    }.each do |owner, error|
      request = push({ "owner" => owner, "visibility" => "details", "events" => [ event("a", title: "Dentist") ],
                       "replace_window" => { "start" => "2026-01-01T00:00:00Z" } })
      assert_equal "failed", request.status, "#{owner} should be refused"
      assert_match error, request.error
    end
    assert_equal 0, CalendarEvent.count, "nothing was stored"

    # Registration is per owner, per agent: marley may push for tessa and not for tester.
    assert_equal 1, push!([ event("a") ], owner: "tessa", agent: @marley).result["stored"]
    assert_match(/marley is not a registered contributor for tester's calendar/, push({ "owner" => "tester", "events" => [] }, agent: @marley).error)

    # And a person takes it away again by deleting the row.
    CalendarContributor.where(owner: @tessa, agent: @marley).delete_all
    assert_equal "failed", push({ "owner" => "tessa", "events" => [ event("b") ] }, agent: @marley).status
    assert_equal 1, CalendarEvent.count
  end

  # 3. With visibility free_busy, titles and locations are absent from the stored records, verified by reading the store directly.
  test "free_busy drops titles and locations at write time, even ones a details push stored earlier" do
    push!([ event("a", title: "Couples therapy", location: "450 Sutter St") ])
    row = CalendarEvent.connection.select_one("SELECT * FROM calendar_events WHERE uid = 'a'")
    assert_nil row["title"]
    assert_nil row["location"]
    assert_equal "free_busy", row["visibility"]
    assert_no_match(/therapy|Sutter/, row.to_json, "nowhere in the row")

    detailed = push!([ event("a", title: "Couples therapy", location: "450 Sutter St") ], visibility: "details")
    assert_nil detailed.result["notice"]
    assert_equal "details", detailed.result["visibility"]
    assert_equal [ "Couples therapy", "450 Sutter St", "details" ], CalendarEvent.find_by!(uid: "a").values_at(:title, :location, :visibility)

    push!([ event("a", title: "Couples therapy", location: "450 Sutter St") ], visibility: "free_busy")
    row = CalendarEvent.connection.select_one("SELECT * FROM calendar_events WHERE uid = 'a'")
    assert_equal [ nil, nil, "free_busy" ], row.values_at("title", "location", "visibility"), "a free_busy re-push clears what details had stored"
  end

  # 4. Re-pushing the same uid updates the existing record rather than duplicating it.
  test "re-pushing a uid updates the record in place" do
    push!([ event("a"), event("b") ], calendar: "work")
    id = CalendarEvent.find_by!(uid: "a").id

    again = push!([ event("a", start: "2026-10-05T13:00:00-07:00", finish: "2026-10-05T14:30:00-07:00", status: "confirmed"), event("z") ], calendar: "work")
    assert_equal [ 1, 1 ], again.result.values_at("stored", "updated")
    assert_equal 3, CalendarEvent.count
    a = CalendarEvent.find_by!(uid: "a")
    assert_equal id, a.id
    assert_equal [ Time.utc(2026, 10, 5, 20), Time.utc(2026, 10, 5, 21, 30), "confirmed" ], [ a.start_at, a.end_at, a.status ]

    # The key is (source_agent, owner, calendar, uid): the same uid from another agent is another event.
    CalendarContributor.create!(owner: @jenner, agent: @marley)
    assert_equal [ 1, 0 ], push!([ event("a") ], calendar: "work", agent: @marley).result.values_at("stored", "updated")
    assert_equal 2, CalendarEvent.where(uid: "a").count
  end

  # 5. replace_window removes previously pushed events in the window that are absent from the batch, and touches no events from other agents or owners.
  test "replace_window removes what the batch left out, inside the window, for this agent, owner and calendar only" do
    CalendarContributor.create!(owner: @jenner, agent: @marley)
    CalendarContributor.create!(owner: @tessa, agent: @skipsy)
    week = { "start" => "2026-10-05T00:00:00-07:00", "end" => "2026-10-12T00:00:00-07:00" }

    push!([ event("kept"), event("gone"), event("before", start: "2026-10-01T09:00:00-07:00", finish: "2026-10-01T10:00:00-07:00"),
            event("after", start: "2026-10-20T09:00:00-07:00", finish: "2026-10-20T10:00:00-07:00") ], calendar: "work")
    push!([ event("other-calendar") ], calendar: "family")
    push!([ event("other-owner") ], owner: "tessa", calendar: "work")
    push!([ event("other-agent") ], calendar: "work", agent: @marley)

    request = push!([ event("kept"), event("new") ], calendar: "work", replace_window: week)
    assert_equal [ 1, 1, 1 ], request.result.values_at("stored", "updated", "removed")
    assert_equal %w[after before kept new other-agent other-calendar other-owner], CalendarEvent.order(:uid).pluck(:uid)

    # A resubmission that is rejected does not cost the good copy already on file.
    malformed = push!([ event("kept", finish: "2026-10-05T08:00:00-07:00") ], calendar: "work", replace_window: week)
    assert_equal [ 0, 0, 1 ], malformed.result.values_at("stored", "updated", "removed"), "new went; kept stayed"
    assert_equal [ { "uid" => "kept", "reason" => "end before start" } ], malformed.result["rejected"]
    assert CalendarEvent.exists?(uid: "kept")

    # One bound is enough: everything from the start on.
    open_ended = push!([], calendar: "work", replace_window: { "start" => "2026-10-05T00:00:00-07:00" })
    assert_equal 2, open_ended.result["removed"]
    assert_equal %w[before other-agent other-calendar other-owner], CalendarEvent.order(:uid).pluck(:uid)
  end

  test "a replace_window that cannot be read refuses the whole push rather than guessing what to delete" do
    push!([ event("a") ])

    {
      "next week" => /replace_window must be an object/,
      {} => /replace_window needs a start or an end/,
      { "start" => "soonish" } => /replace_window.start must be an ISO8601 date-time with a UTC offset, got "soonish"/,
      { "start" => "2026-10-05T00:00:00" } => /replace_window.start must be an ISO8601 date-time with a UTC offset/,
      { "start" => "2026-10-05T00:00:00Z", "end" => 7 } => /replace_window.end must be an ISO8601 date-time/,
      { "start" => "2026-10-12T00:00:00Z", "end" => "2026-10-05T00:00:00Z" } => /replace_window ends before it starts/
    }.each do |window, error|
      request = push({ "owner" => "tester", "events" => [ event("b") ], "replace_window" => window })
      assert_equal "failed", request.status, "#{window.inspect} should be refused"
      assert_match error, request.error
    end
    assert_equal %w[a], CalendarEvent.pluck(:uid), "nothing removed, and the batch beside the bad window was not stored either"
  end

  # 6. Malformed events (end before start, missing uid, >30 day span) are rejected individually and reported, while valid events in the same batch still store.
  test "malformed events are rejected one by one while the rest of the batch stores" do
    request = push!([
      event("good"),
      event("backwards", finish: "2026-10-05T08:00:00-07:00"),
      { "start" => "2026-10-05T09:00:00-07:00", "end" => "2026-10-05T10:00:00-07:00" },
      event("sabbatical", finish: "2026-11-05T09:00:01-07:00"),
      event("month", finish: "2026-11-04T09:00:00-07:00"),
      event("floating", start: "2026-10-05T09:00:00", finish: "2026-10-05T10:00:00"),
      event("vague", start: "monday"),
      event("endless").except("end"),
      event("maybe", status: "probably"),
      event("flagged", all_day: "yes"),
      event("idle", busy: nil),
      event("good"),
      event(42),
      "not an event",
      event("instant", finish: "2026-10-05T09:00:00-07:00")
    ])

    assert_equal [ 3, 0 ], request.result.values_at("stored", "updated")
    assert_equal %w[good instant month], CalendarEvent.order(:uid).pluck(:uid), "exactly 30 days and zero-length are fine"
    assert_equal [
      { "uid" => "backwards", "reason" => "end before start" },
      { "uid" => "(missing)", "reason" => "missing uid" },
      { "uid" => "sabbatical", "reason" => "spans more than 30 days" },
      { "uid" => "floating", "reason" => "start and end must be ISO8601 date-times with a UTC offset" },
      { "uid" => "vague", "reason" => "start and end must be ISO8601 date-times with a UTC offset" },
      { "uid" => "endless", "reason" => "start and end must be ISO8601 date-times with a UTC offset" },
      { "uid" => "maybe", "reason" => "status must be one of confirmed, tentative, cancelled" },
      { "uid" => "flagged", "reason" => "all_day must be true or false" },
      { "uid" => "idle", "reason" => "busy must be true or false" },
      { "uid" => "good", "reason" => "duplicate uid in this batch" },
      { "uid" => "(missing)", "reason" => "uid must be a string of at most 1024 characters" },
      { "uid" => "(missing)", "reason" => "must be an object" }
    ], request.result["rejected"]
  end

  test "title and location are held to 200 characters where they would be stored, and ignored where they would not" do
    long = "x" * 201
    detailed = push!([ event("long-title", title: long), event("long-place", location: long), event("odd", title: 42),
                       event("fits", title: "y" * 200, location: "") ], visibility: "details")
    assert_equal [
      { "uid" => "long-title", "reason" => "title must be text of at most 200 characters" },
      { "uid" => "long-place", "reason" => "location must be text of at most 200 characters" },
      { "uid" => "odd", "reason" => "title must be text of at most 200 characters" }
    ], detailed.result["rejected"]
    assert_equal [ "y" * 200, nil ], CalendarEvent.find_by!(uid: "fits").values_at(:title, :location)

    # A busy block is not lost over a title that was never going to be kept.
    assert_equal [ 1, [] ], push!([ event("long-title", title: long) ]).result.values_at("stored", "rejected")
  end

  test "bad input: no owner, events that are not a list or too many, an unknown visibility, a calendar that is not a label" do
    assert_match(/owner is required/, push({ "events" => [] }).error)
    assert_match(/events must be an array/, push({ "owner" => "tester" }).error)
    assert_match(/events must be an array/, push({ "owner" => "tester", "events" => event("a") }).error)
    assert_match(/events exceeds 200/, push({ "owner" => "tester", "events" => Array.new(201) { |i| event("e#{i}") } }).error)
    assert_match(/visibility must be one of free_busy, details, got "public"/, push({ "owner" => "tester", "events" => [], "visibility" => "public" }).error)
    assert_match(/calendar must be a label/, push({ "owner" => "tester", "events" => [], "calendar" => [ "work" ] }).error)
    assert_match(/calendar must be a label/, push({ "owner" => "tester", "events" => [], "calendar" => "w" * 201 }).error)
    assert_equal 0, CalendarEvent.count

    assert_equal 200, push!(Array.new(200) { |i| event("e#{i}") }).result["stored"]
  end

  test "a push lands whole or not at all: a fault part-way through leaves the mirror as it was" do
    push!([ event("kept") ])
    lookup = CalendarEvent.method(:find_or_initialize_by)
    CalendarEvent.define_singleton_method(:find_or_initialize_by) do |attributes|
      attributes[:uid] == "boom" ? raise(ActiveRecord::StatementInvalid, "the database went away") : lookup.call(attributes)
    end

    request = push({ "owner" => "tester", "events" => [ event("first"), event("boom") ], "replace_window" => { "start" => "2026-01-01T00:00:00Z" } })
    assert_equal "failed", request.status
    assert_match(/the database went away/, request.error)
    assert_equal %w[kept], CalendarEvent.pluck(:uid), "first was rolled back and kept was not removed"
  ensure
    CalendarEvent.singleton_class.send(:remove_method, :find_or_initialize_by)
  end

  # 7. No credential or external endpoint is ever read or written by the handler.
  test "the handler reaches nothing outside hob and the mirror has nowhere to keep a credential" do
    outbound = without_network do
      push!([ event("a", title: "Dentist", location: "https://zoom.us/j/123?pwd=hunter2") ], visibility: "details", calendar: "work",
            replace_window: { "start" => "2026-10-01T00:00:00Z", "end" => "2026-11-01T00:00:00Z" })
    end
    assert_empty outbound
    assert_empty @fake.calls, "no model call either"

    assert_equal %w[all_day busy calendar created_at end_at id location owner_id source_agent_id start_at status title uid updated_at visibility],
                 CalendarEvent.column_names.sort
    assert_equal %w[agent_id created_at id owner_id updated_at], CalendarContributor.column_names.sort
  end

  test "the spec's grant applies: under review the reviewer sees the push, and its verdict decides" do
    SentinelPolicy.delete_all
    policy!(@skipsy, "hob.calendar.push", "review", guidance: "Jenner's calendars only.")
    @fake.reply('{"verdict": "approve", "rationale": "a routine sync"}')
    ok = push({ "owner" => "tester", "events" => [ event("a") ] })
    assert_equal "completed", ok.status, ok.error.to_s
    assert_equal "reviewer", ok.decided_by
    assert_match(/"owner": "tester"/, @fake.calls.last.messages.last["content"])
    assert_match(/Jenner's calendars only/, @fake.calls.last.system)

    @fake.reply('{"verdict": "deny", "rationale": "not a sync"}')
    assert_equal "denied", push({ "owner" => "tester", "events" => [ event("b") ] }).status
    assert_equal "denied", push({ "owner" => "tester", "events" => [] }, agent: @marley).status, "marley has no policy at all"
    assert_equal %w[a], CalendarEvent.pluck(:uid)
  end

  test "the models keep owners people, contributors agents, and free_busy rows free of details" do
    assert_raises(ActiveRecord::RecordInvalid) { CalendarContributor.create!(owner: @skipsy, agent: @marley) }
    assert_raises(ActiveRecord::RecordInvalid) { CalendarContributor.create!(owner: @tessa, agent: @jenner) }
    assert_raises(ActiveRecord::RecordInvalid) { CalendarContributor.create!(owner: @jenner, agent: @skipsy) }

    times = { start_at: Time.utc(2026, 10, 5, 16), end_at: Time.utc(2026, 10, 5, 17) }
    assert_raises(ActiveRecord::RecordInvalid) { CalendarEvent.create!(source_agent: @jenner, owner: @jenner, uid: "a", **times) }
    assert_raises(ActiveRecord::RecordInvalid) { CalendarEvent.create!(source_agent: @skipsy, owner: @marley, uid: "a", **times) }
    assert_raises(ActiveRecord::RecordInvalid) { CalendarEvent.create!(source_agent: @skipsy, owner: @jenner, uid: "a", title: "Dentist", **times) }
    assert_raises(ActiveRecord::RecordInvalid) { CalendarEvent.create!(source_agent: @skipsy, owner: @jenner, uid: "a", start_at: times[:end_at], end_at: times[:start_at]) }
    assert CalendarEvent.create!(source_agent: @skipsy, owner: @jenner, uid: "a", title: "Dentist", visibility: "details", **times).persisted?
  end
end
