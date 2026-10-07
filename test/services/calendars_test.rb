require "test_helper"
require_relative "../support/fake_calendars"

# Calendars (CALENDARS.md) over the ics and fastmail adapters, with the
# servers faked at the transport: what hob sends (URLs, CalDAV bodies, the
# app password), what the façade merges, trims, and sorts, what a
# free_busy row hides, and what each kind of failure becomes.
class CalendarsTest < ActiveSupport::TestCase
  LA = ActiveSupport::TimeZone["America/Los_Angeles"]
  FEED = "https://example.test/family-ics.ics".freeze

  def ics(*vevents, name: nil)
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\n#{name && "X-WR-CALNAME:#{name}\r\n"}#{vevents.join}END:VCALENDAR\r\n"
  end

  def vevent(uid, start, finish, summary, extra = "")
    "BEGIN:VEVENT\r\nUID:#{uid}\r\nDTSTART;TZID=America/Los_Angeles:#{start}\r\nDTEND;TZID=America/Los_Angeles:#{finish}\r\n" \
      "SUMMARY:#{summary}\r\n#{extra}END:VEVENT\r\n"
  end

  setup do
    ENV["HOB_TEST_CALDAV_KEY"] = "app-password"
    ENV["HOB_TIME_ZONE"] = "America/Los_Angeles"
    Calendars::Backends::Base.transport = (@server = FakeCalendars.new).to_proc
    @server.feed(FEED, ics(vevent("soccer@x", "20261007T170000", "20261007T183000", "Soccer practice", "LOCATION:Field 3\r\n"),
                           vevent("recital@x", "20261009T180000", "20261009T200000", "Recital"), name: "Kids"))
    @server.calendar("work-id", "Work", [ ics(vevent("1on1@x", "20261007T100000", "20261007T103000", "1:1 with Sam")) ])
    @server.calendar("family-id", "Family", [
      ics(vevent("dinner@x", "20261008T190000", "20261008T210000", "Dinner at Nonna's")),
      ics(vevent("dentist@x", "20261007T080000", "20261007T090000", "Dentist", "STATUS:CANCELLED\r\n"))
    ], read_only: true)
  end

  teardown do
    Calendars::Backends::Base.transport = nil
    ENV.delete("HOB_TEST_CALDAV_KEY")
    ENV.delete("HOB_TIME_ZONE")
  end

  def week
    { "from" => "2026-10-05", "to" => "2026-10-12" }
  end

  test "a feed is one calendar, named by the feed unless the row names it" do
    calendar_backend("family-ics")
    assert_equal [ { "id" => "family-ics:feed", "backend" => "family-ics", "name" => "Kids", "color" => nil, "read_only" => true,
                     "time_zone" => "America/Los_Angeles" } ], Calendars.calendars["calendars"]
    CalendarBackend.find_by!(name: "family-ics").update!(config: { "url" => FEED, "name" => "Soccer & such" })
    assert_equal "Soccer & such", Calendars.calendars.dig("calendars", 0, "name")
    assert_equal [ "GET", FEED ], @server.calls.last.to_a.first(2)
  end

  test "events merge across backends, soonest first, in the window, cancelled ones left out" do
    calendar_backend("family-ics")
    calendar_backend("jenner-fastmail", kind: "fastmail")
    result = Calendars.events(week)
    assert_equal [ "1:1 with Sam", "Soccer practice", "Dinner at Nonna's", "Recital" ], result["events"].map { |e| e["title"] }
    assert_equal [ "2026-10-05T00:00:00-07:00", "2026-10-12T00:00:00-07:00" ], result.values_at("from", "to")
    assert_equal [ 4, false, [] ], result.values_at("matched", "truncated", "unavailable")

    soccer = result["events"].find { |e| e["uid"] == "soccer@x" }
    assert_equal({ "id" => "family-ics:feed:soccer@x", "backend" => "family-ics", "calendar" => { "id" => "family-ics:feed", "name" => "Kids" },
                   "uid" => "soccer@x", "recurrence_id" => nil, "title" => "Soccer practice", "location" => "Field 3",
                   "description" => nil, "url" => nil, "start" => "2026-10-07T17:00:00-07:00", "end" => "2026-10-07T18:30:00-07:00",
                   "all_day" => false, "time_zone" => "America/Los_Angeles", "status" => "confirmed", "busy" => true,
                   "recurring" => false }, soccer)
    refute result["events"].any? { |e| e.keys.any? { |k| k.start_with?("_") } }, "the façade's sort keys stay inside"

    assert_equal [ "Dentist" ], Calendars.events(week.merge("cancelled" => true, "q" => "dentist"))["events"].map { |e| e["title"] }
    assert_equal [ "Soccer practice" ], Calendars.events(week.merge("q" => "field"))["events"].map { |e| e["title"] }
    limited = Calendars.events(week.merge("limit" => 2))
    assert_equal [ 2, 4, true ], [ limited["events"].size, limited["matched"], limited["truncated"] ]
  end

  test "fastmail: the calendar home from the username, the app password, a time-range REPORT per calendar" do
    calendar_backend("jenner-fastmail", kind: "fastmail")
    calendars = Calendars.calendars["calendars"]
    assert_equal [ [ "jenner-fastmail:work-id", "Work", false, "#3a87ad" ], [ "jenner-fastmail:family-id", "Family", true, "#3a87ad" ] ],
                 calendars.map { |c| c.values_at("id", "name", "read_only", "color") }, "the home and the scheduling inbox are not calendars"

    propfind = @server.calls.last
    assert_equal [ "PROPFIND", FakeCalendars::HOME, "1" ], [ propfind.verb, propfind.url, propfind.headers["Depth"] ]
    assert_equal "Basic #{Base64.strict_encode64('jenner@fastmail.test:app-password')}", propfind.headers["Authorization"]

    @server.calls.clear
    Calendars.events(week.merge("calendar" => "jenner-fastmail:family-id"))
    report = @server.calls.find { |call| call.verb == "REPORT" }
    assert_equal "#{FakeCalendars::HOME}family-id/", report.url
    assert_match(/<c:time-range start="20261005T070000Z" end="20261012T070000Z"\/>/, report.body)
    assert_equal 1, @server.calls.count { |call| call.verb == "REPORT" }, "only the calendar asked about"
  end

  test "a row's calendars list confines it: the rest of the account does not exist for it" do
    calendar_backend("house-fastmail", kind: "fastmail", calendars: [ "family" ])
    assert_equal [ "Family" ], Calendars.calendars["calendars"].map { |c| c["name"] }
    assert_equal [ "Dinner at Nonna's" ], Calendars.events(week)["events"].map { |e| e["title"] }
    assert_equal [], Calendars.events(week.merge("calendar" => "house-fastmail:work-id"))["events"]
  end

  test "a free_busy row hands out when and whether busy, never what or where, and q cannot find what it hid" do
    calendar_backend("family-ics", visibility: "free_busy")
    soccer = Calendars.events(week)["events"].first
    assert_equal [ nil, nil, nil, nil ], soccer.values_at("title", "location", "description", "url")
    assert_equal [ "2026-10-07T17:00:00-07:00", "2026-10-07T18:30:00-07:00", true ], soccer.values_at("start", "end", "busy")
    assert_equal [], Calendars.events(week.merge("q" => "soccer"))["events"]
  end

  test "a backend that cannot answer is named in unavailable; asked for by name, it fails the call" do
    calendar_backend("family-ics")
    calendar_backend("jenner-fastmail", kind: "fastmail")
    ENV.delete("HOB_TEST_CALDAV_KEY")
    result = Calendars.events(week)
    assert_equal 2, result["events"].size
    assert_equal [ { "backend" => "jenner-fastmail", "error" => "jenner-fastmail has no password: HOB_TEST_CALDAV_KEY is not set in hob's environment" } ],
                 result["unavailable"]
    assert_raises(Calendars::Unavailable) { Calendars.events(week.merge("backend" => "jenner-fastmail")) }

    ENV["HOB_TEST_CALDAV_KEY"] = "wrong"
    @server.respond(401, "")
    assert_match(/refused jenner-fastmail's credentials/, assert_raises(Calendars::Forbidden) { Calendars.calendars("backend" => "jenner-fastmail") }.message)
  end

  test "feeds: redirects are followed, webcal is https, and what is not a calendar is Unavailable" do
    calendar_backend("family-ics", url: "webcal://example.test/old.ics")
    @server.respond(301, "", { "Location" => "/family-ics.ics" })
    assert_equal "Kids", Calendars.calendars.dig("calendars", 0, "name")
    assert_equal [ "https://example.test/old.ics", FEED ], @server.calls.map(&:url)

    @server.respond(200, "<html>Sign in to Google</html>")
    assert_match(/not an iCalendar document/, assert_raises(Calendars::Unavailable) { Calendars.calendars("backend" => "family-ics") }.message)
    @server.respond(404, "")
    assert_match(/found nothing there \(HTTP 404\)/, assert_raises(Calendars::Unavailable) { Calendars.calendars("backend" => "family-ics") }.message)
    6.times { @server.respond(302, "", { "location" => "https://example.test/loop.ics" }) }
    assert_match(/too many redirects/, assert_raises(Calendars::Unavailable) { Calendars.calendars("backend" => "family-ics") }.message)
  end

  test "the window: a date is local midnight, a time needs its offset, at most #{Calendars::MAX_DAYS} days; unknown filters are refused" do
    calendar_backend("family-ics")
    travel_to Time.utc(2026, 10, 7, 12, 0) do
      result = Calendars.events
      assert_equal [ "2026-10-07T05:00:00-07:00", "2026-10-14T05:00:00-07:00" ], result.values_at("from", "to"), "now, for a week"
      assert_equal [ "Soccer practice", "Recital" ], result["events"].map { |e| e["title"] }
    end
    assert_equal 1, Calendars.events("from" => "2026-10-09T17:00:00-07:00", "to" => "2026-10-09T19:00:00-07:00")["events"].size

    invalid = ->(filters) { assert_raises(Calendars::Invalid) { Calendars.events(filters) }.message }
    assert_match(/time with an offset/, invalid.("from" => "2026-10-09T17:00:00"))
    assert_match(/spans more than 92 days/, invalid.("from" => "2026-01-01", "to" => "2026-06-01"))
    assert_match(/is not after from/, invalid.("from" => "2026-10-09", "to" => "2026-10-09"))
    assert_match(/unknown filter since/, invalid.("since" => "2026-10-01"))
    assert_match(/more than one backend/, invalid.("calendar" => [ "a:x", "b:y" ]))
    assert_match(/look like <backend>:<id>/, invalid.("calendar" => "work"))
    assert_raises(Calendars::NotFound) { Calendars.events("backend" => "nobody") }
  end
end
