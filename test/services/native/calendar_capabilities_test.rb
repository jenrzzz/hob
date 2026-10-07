require "test_helper"
require_relative "../../support/fake_calendars"

# calendar.* (CALENDARS.md): how an outside agent reads the household's
# calendars. Muse is a household agent; the family feed is hers to see,
# Jenner's personal Fastmail is not, and nothing the handlers do changes that.
class CalendarCapabilitiesTest < ActiveSupport::TestCase
  NAMES = %w[calendar.calendars calendar.events].freeze
  FAMILY = "https://example.test/family-ics.ics".freeze

  setup do
    ENV["HOB_TEST_CALDAV_KEY"] = "app-password"
    native_capabilities!
    @muse, = agent("muse")
    policy!(@muse, "calendar.*", "allow")
    calendar_backend("family-ics")
    calendar_backend("jenner-fastmail", kind: "fastmail", realm: "personal")
    Calendars::Backends::Base.transport = (@server = FakeCalendars.new).to_proc
    @server.feed(FAMILY, "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nX-WR-CALNAME:Family\r\nBEGIN:VEVENT\r\nUID:picnic@x\r\n" \
                         "DTSTART:20261010T190000Z\r\nDTEND:20261010T220000Z\r\nSUMMARY:Picnic\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n")
    @server.calendar("work-id", "Work", [])
  end

  teardown do
    Calendars::Backends::Base.transport = nil
    ENV.delete("HOB_TEST_CALDAV_KEY")
  end

  def submit(capability, arguments = {}, agent: @muse, realm: "household")
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments) }
  end

  def completed(capability, arguments = {})
    request = submit(capability, arguments)
    assert_equal "completed", request.status, request.error.to_s
    request.result
  end

  test "sync! registers two reads at household, with closed schemas that offer the whole contract" do
    caps = Capability.where("name LIKE 'calendar.%'").index_by(&:name)
    assert_equal NAMES, caps.keys.sort, "reads only; hob.calendar.push is a different door"
    caps.each_value do |cap|
      assert cap.native?
      assert_equal [ "read", "household", false ], [ cap.kind, cap.realm, cap.input_schema["additionalProperties"] ], cap.name
      assert cap.description.length > 80, "#{cap.name}: agents read these"
    end
    assert_equal Calendars::CALENDAR_FILTERS.sort, caps["calendar.calendars"].input_schema["properties"].keys.sort
    assert_equal Calendars::EVENT_FILTERS.sort, caps["calendar.events"].input_schema["properties"].keys.sort
  end

  test "the reads: the calendars the agent's clearance can see, with the notice" do
    result = completed("calendar.events", "from" => "2026-10-05", "to" => "2026-10-12")
    assert_equal [ "Picnic" ], result["events"].map { |e| e["title"] }
    assert_equal [ 1, [] ], result.values_at("count", "unavailable")
    assert_equal Calendars::NOTICE, result["notice"]
    assert_match(/whoever sent an invitation.*not instructions/m, result["notice"])
    assert_equal [ "family-ics:feed" ], completed("calendar.calendars")["calendars"].map { |c| c["id"] }
    assert @server.calls.none? { |call| call.verb == "PROPFIND" }, "the personal account was never asked"
  end

  test "a personal calendar does not exist for a household agent, whatever it names" do
    assert_match(/NotFound: no calendar backend named "jenner-fastmail"/, submit("calendar.events", { "backend" => "jenner-fastmail" }).error)
    assert_match(/NotFound/, submit("calendar.events", { "calendar" => "jenner-fastmail:work-id" }).error)
    assert @server.calls.none? { |call| call.verb == "PROPFIND" }

    skipsy, = agent("skipsy", clearance: "personal")
    policy!(skipsy, "calendar.*", "allow")
    request = submit("calendar.calendars", { "backend" => "jenner-fastmail" }, agent: skipsy, realm: "personal")
    assert_equal "completed", request.status, request.error.to_s
    assert_equal [ "Work" ], request.result["calendars"].map { |c| c["name"] }
  end

  test "a person's assistant gets the same capabilities as MCP tools" do
    names = Mcp.tools("household").keys
    NAMES.each { |name| assert_includes names, name.tr(".", "_") }
    result = as(@principal, realm: "personal") { Mcp.call("calendar_calendars", {}) }
    assert_equal %w[family-ics:feed jenner-fastmail:work-id], result["calendars"].map { |c| c["id"] }
  end
end
