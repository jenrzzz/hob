require "test_helper"

# Calendars::Ical (CALENDARS.md): iCalendar text into the contract's events
# for a window. What a repeating event becomes, what its exceptions do, and
# where a time with a zone, without one, or with one nobody defined lands.
class CalendarsIcalTest < ActiveSupport::TestCase
  LA = ActiveSupport::TimeZone["America/Los_Angeles"]
  CALENDAR = { "id" => "family:feed", "name" => "Family" }.freeze

  def ics(*vevents, extra: "")
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//test//EN\r\n#{extra}#{vevents.join}END:VCALENDAR\r\n"
  end

  def vevent(uid, lines)
    "BEGIN:VEVENT\r\nUID:#{uid}\r\nDTSTAMP:20261001T000000Z\r\n#{lines.strip.gsub(/\n\s*/, "\r\n")}\r\nEND:VEVENT\r\n"
  end

  def events(text, from: LA.parse("2026-10-01"), to: LA.parse("2026-11-15"), zone: LA)
    Calendars::Ical.events(text, from: from, to: to, zone: zone, calendar: CALENDAR, id_prefix: "family:feed")
  end

  STANDUP = <<~ICS.freeze
    DTSTART;TZID=America/Los_Angeles:20261005T090000
    DTEND;TZID=America/Los_Angeles:20261005T093000
    RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=10
    EXDATE;TZID=America/Los_Angeles:20261012T090000
    SUMMARY:Standup
  ICS

  test "a weekly series is one event per occurrence, 9:00 local on both sides of the DST change" do
    found = events(ics(vevent("standup@x", STANDUP)))
    assert_equal [ "2026-10-05T09:00:00-07:00", "2026-10-19T09:00:00-07:00", "2026-10-26T09:00:00-07:00",
                   "2026-11-02T09:00:00-08:00", "2026-11-09T09:00:00-08:00" ], found.map { |e| e["start"] }, "the 12th is EXDATEd"
    assert_equal "2026-10-05T09:30:00-07:00", found.first["end"]
    assert found.all? { |e| e["recurring"] && e["uid"] == "standup@x" && e["time_zone"] == "America/Los_Angeles" }
    assert_equal "family:feed:standup@x@20261005T160000Z", found.first["id"]
    assert_equal "2026-10-05T16:00:00Z", found.first["recurrence_id"]
    assert_equal found.map { |e| e["id"] }.uniq.size, found.size, "every occurrence has its own id"
  end

  test "an exception replaces the occurrence it names: moved, retitled, or cancelled" do
    moved = vevent("standup@x", <<~ICS)
      RECURRENCE-ID;TZID=America/Los_Angeles:20261019T090000
      DTSTART;TZID=America/Los_Angeles:20261019T100000
      DTEND;TZID=America/Los_Angeles:20261019T103000
      SUMMARY:Standup (moved)
    ICS
    cancelled = vevent("standup@x", <<~ICS)
      RECURRENCE-ID;TZID=America/Los_Angeles:20261026T090000
      DTSTART;TZID=America/Los_Angeles:20261026T090000
      STATUS:CANCELLED
      SUMMARY:Standup
    ICS
    found = events(ics(vevent("standup@x", STANDUP), moved, cancelled)).index_by { |e| e["recurrence_id"] }
    assert_equal [ "2026-10-19T10:00:00-07:00", "Standup (moved)" ], found["2026-10-19T16:00:00Z"].values_at("start", "title")
    assert_equal [ "cancelled", false ], found["2026-10-26T16:00:00Z"].values_at("status", "busy")
    assert_equal 5, found.size, "replaced, not added to"
  end

  test "an exception moved into the window from a slot outside it is still found" do
    moved = vevent("standup@x", <<~ICS)
      RECURRENCE-ID;TZID=America/Los_Angeles:20261005T090000
      DTSTART;TZID=America/Los_Angeles:20261021T150000
      DTEND;TZID=America/Los_Angeles:20261021T153000
      SUMMARY:Standup (made up)
    ICS
    found = events(ics(vevent("standup@x", STANDUP), moved), from: LA.parse("2026-10-20"), to: LA.parse("2026-10-23"))
    assert_equal [ [ "2026-10-21T15:00:00-07:00", "Standup (made up)" ] ], found.map { |e| e.values_at("start", "title") }
  end

  test "all-day events are dates, the end exclusive; a yearly one recurs from long ago" do
    birthday = vevent("bday@x", "DTSTART;VALUE=DATE:19901010\nRRULE:FREQ=YEARLY\nSUMMARY:Birthday")
    trip = vevent("trip@x", "DTSTART;VALUE=DATE:20261030\nDTEND;VALUE=DATE:20261102\nSUMMARY:Trip\nTRANSP:TRANSPARENT")
    found = events(ics(birthday, trip)).index_by { |e| e["uid"] }
    assert_equal [ "2026-10-10", "2026-10-11", true, nil ], found["bday@x"].values_at("start", "end", "all_day", "time_zone")
    assert_equal [ "2026-10-30", "2026-11-02", false ], found["trip@x"].values_at("start", "end", "busy")
    assert_equal LA.parse("2026-10-10"), found["bday@x"]["_starts"], "sorted at local midnight"
  end

  test "UTC stays UTC, floating and unknown zones are read in the backend's zone, a VTIMEZONE is honoured" do
    vtimezone = <<~ICS.gsub("\n", "\r\n")
      BEGIN:VTIMEZONE
      TZID:Custom Eastern
      BEGIN:DAYLIGHT
      DTSTART:19700308T020000
      RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU
      TZOFFSETFROM:-0500
      TZOFFSETTO:-0400
      END:DAYLIGHT
      BEGIN:STANDARD
      DTSTART:19701101T020000
      RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU
      TZOFFSETFROM:-0400
      TZOFFSETTO:-0500
      END:STANDARD
      END:VTIMEZONE
    ICS
    text = ics(vevent("utc@x", "DTSTART:20261006T170000Z\nDURATION:PT1H\nSUMMARY:UTC"),
               vevent("float@x", "DTSTART:20261006T170000\nSUMMARY:Floating"),
               vevent("nowhere@x", "DTSTART;TZID=Nowhere/Land:20261006T170000\nSUMMARY:Nowhere"),
               vevent("custom@x", "DTSTART;TZID=Custom Eastern:20261006T170000\nSUMMARY:Custom"), extra: vtimezone)
    found = events(text).index_by { |e| e["uid"] }
    assert_equal [ "2026-10-06T17:00:00Z", "2026-10-06T18:00:00Z" ], found["utc@x"].values_at("start", "end")
    assert_equal [ "2026-10-06T17:00:00-07:00", "America/Los_Angeles" ], found["float@x"].values_at("start", "time_zone")
    assert_equal "2026-10-06T17:00:00-07:00", found["nowhere@x"]["start"]
    assert_equal [ "2026-10-06T17:00:00-04:00", "Custom Eastern" ], found["custom@x"].values_at("start", "time_zone")
    assert_equal found["float@x"]["start"], found["float@x"]["end"], "no DTEND and no DURATION: an instant"
  end

  test "only what overlaps the window comes back, including what began before it" do
    text = ics(vevent("before@x", "DTSTART:20261001T100000Z\nDTEND:20261001T110000Z\nSUMMARY:Before"),
               vevent("spanning@x", "DTSTART:20261009T220000Z\nDTEND:20261010T020000Z\nSUMMARY:Late"),
               vevent("after@x", "DTSTART:20261011T000000Z\nSUMMARY:After"),
               vevent("nightly@x", "DTSTART:20260101T230000Z\nDTEND:20260102T010000Z\nRRULE:FREQ=DAILY\nSUMMARY:Nightly"))
    found = events(text, from: Time.utc(2026, 10, 10), to: Time.utc(2026, 10, 11))
    assert_equal [ [ "spanning@x", "2026-10-09T22:00:00Z" ], [ "nightly@x", "2026-10-09T23:00:00Z" ], [ "nightly@x", "2026-10-10T23:00:00Z" ] ],
                 found.map { |e| e.values_at("uid", "start") }.sort_by(&:last)
  end

  test "text is trimmed and capped, and statuses are the contract's" do
    text = ics(vevent("long@x", "DTSTART:20261006T170000Z\nSUMMARY:  Dentist  \nDESCRIPTION:#{'x' * 3000}\nSTATUS:TENTATIVE\nLOCATION:Main St"),
               vevent("odd@x", "DTSTART:20261006T170000Z\nSTATUS:WHATEVER"))
    found = events(text).index_by { |e| e["uid"] }
    assert_equal [ "Dentist", "Main St", "tentative" ], found["long@x"].values_at("title", "location", "status")
    assert_equal Calendars::Ical::DESCRIPTION_LIMIT, found["long@x"]["description"].length
    assert_equal [ nil, "confirmed" ], found["odd@x"].values_at("title", "status")
  end

  test "a document that is not a calendar is Unavailable" do
    assert_raises(Calendars::Unavailable) { Calendars::Ical.parse("<html>sign in</html>") }
  end
end
