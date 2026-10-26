require "test_helper"
require_relative "../support/fake_herald"

# People::Sync (PEOPLE.md): texts become events and loops without anyone
# writing them down. herald is faked at the transport; the motivating
# example is the first test.
class PeopleSyncTest < ActiveSupport::TestCase
  EUGENE = "any;-;+15550001111".freeze
  GANG = "any;+;chat-biker".freeze

  setup do
    ENV["HOB_TEST_HERALD_KEY"] = FakeHerald::KEY
    ENV["HOB_TIME_ZONE"] = "America/Los_Angeles"
    Texts::Backends::Herald.transport = (@herald = FakeHerald.new).to_proc
    @herald.chat(EUGENE, name: "Eugene Fox")
    @herald.chat(GANG, name: "Biker Gang", group: true, handles: %w[+15550001111 +15550002222])
    @backend = text_backend
  end

  teardown do
    Texts::Backends::Herald.transport = nil
    ENV.delete("HOB_TEST_HERALD_KEY")
    ENV.delete("HOB_TIME_ZONE")
  end

  def sync
    Clearance.with("intimate") { People::Sync.run! }
  end

  test "Eugene: the text that sat for eight days opens a loop, and the reply from a phone closes it" do
    assert_equal [ "jenner-messages: 0 seen, 0 new events, 0 loops opened, 0 closed" ], sync.map(&:to_s), "a first run notes where the stream is"
    assert PeopleCursor.find_by(source: "text:jenner-messages").cursor

    @herald.message(EUGENE, "how's your baby and dad life?", at: "2026-10-07T18:00:00Z", from: "+15550001111", name: "Eugene Fox")
    assert_equal 1, sync.first.opened

    eugene = Person.sole
    assert_equal [ "Eugene Fox", "personal", @principal ], [ eugene.display_name, eugene.realm, eugene.principal ]
    event = PeopleEvent.sole
    assert_equal [ "reached_out", "inbound", "text", "text", "jenner-messages:G-1001" ],
                 event.values_at(:kind, :direction, :channel, :source_kind, :source_ref)
    assert_equal "text from Eugene Fox", event.summary
    refute_includes event.summary, "baby", "the event cites the message; hob keeps none of its body"

    travel_to Time.iso8601("2026-10-15T18:00:00Z") do
      loop = People.loops("older_than" => 7)["loops"].sole
      assert_equal [ "unanswered_inbound", 8, "Eugene Fox" ], [ loop["kind"], loop["age_days"], loop.dig("person", "display_name") ]
    end

    @herald.message(EUGENE, "So good. Long story, call this week?", at: "2026-10-15T19:00:00Z")
    assert_equal 1, sync.first.closed
    assert_empty People.loops["loops"]
    assert_equal %w[replied reached_out], PeopleEvent.order(at: :desc).pluck(:kind)
  end

  test "running again derives nothing twice" do
    sync
    @herald.message(EUGENE, "hi", at: "2026-10-07T18:00:00Z", from: "+15550001111", name: "Eugene Fox")
    sync
    PeopleCursor.update_all(cursor: nil)
    People::Sync.backfill!(@backend, since: Time.iso8601("2026-10-01T00:00:00Z"))
    assert_equal 1, PeopleEvent.count
    assert_equal 1, PeopleLoop.count
  end

  test "a group chat's messages are the group's: members kept, nothing opened" do
    sync
    @herald.message(GANG, "ride saturday?", at: "2026-10-07T18:00:00Z", from: "+15550002222", name: "Jarret")
    @herald.message(GANG, "in", at: "2026-10-07T18:05:00Z")
    report = sync.first
    assert_equal [ 2, 0 ], [ report.derived, report.opened ]

    group = PeopleGroup.sole
    assert_equal [ "Biker Gang", "text:jenner-messages:#{GANG}", "personal" ], [ group.name, group.chat_ref, group.realm ]
    assert_equal %w[+15550001111 +15550002222], group.people.flat_map { |p| p.handles.map(&:address) }.sort
    assert_equal [ [ "inbound", "text in Biker Gang from Jarret" ], [ "outbound", "text in Biker Gang" ] ],
                 PeopleEvent.order(:at).map { |e| [ e.direction, e.summary ] }
    assert PeopleEvent.where.not(group_id: nil).count == 2
    assert_equal [ "Biker Gang" ], People.get("person" => "+15550001111")["groups"].map { |g| g["name"] }
  end

  test "a short-code sender is automated and opens nothing" do
    sync
    @herald.chat("any;-;72727", name: "72727")
    @herald.message("any;-;72727", "Your code is 123456", at: "2026-10-07T18:00:00Z", from: "72727")
    assert_equal 0, sync.first.opened
    assert Person.sole.automated
  end

  test "backfill reads back oldest first, so what was already answered stays closed" do
    sync
    @herald.message(EUGENE, "you around?", at: "2026-10-01T18:00:00Z", from: "+15550001111", name: "Eugene Fox")
    @herald.message(EUGENE, "yep", at: "2026-10-01T18:10:00Z")
    @herald.message(EUGENE, "how's your baby and dad life?", at: "2026-10-07T18:00:00Z", from: "+15550001111", name: "Eugene Fox")
    PeopleCursor.update_all(cursor: nil)

    report = People::Sync.backfill!(@backend, since: Time.iso8601("2026-09-01T00:00:00Z"))
    assert_equal [ 3, 3 ], [ report.seen, report.derived ]
    loop = PeopleLoop.outstanding.sole
    assert_equal Time.iso8601("2026-10-07T18:00:00Z"), loop.opened_at
    assert_equal 1, PeopleLoop.where(state: "closed").count
  end

  test "seeding makes people and groups from the chats, without events" do
    result = Clearance.with("intimate") { People::Sync.seed!(@backend) }
    assert_equal({ people: 2, groups: 1, chats: 2 }, result)
    assert_equal 0, PeopleEvent.count
    assert_equal "Eugene Fox", People.person!("+15550001111").display_name
  end

  test "a group chat named by everyone in it is clipped to fit" do
    @herald.chat("any;+;chat-crowd", name: Array.new(40) { |i| "Person Number #{i}" }.join(", "), group: true, handles: %w[+15550003333])
    Clearance.with("intimate") { People::Sync.seed!(@backend) }
    name = PeopleGroup.find_by!(chat_ref: "text:jenner-messages:any;+;chat-crowd").name
    assert_equal PeopleGroup::NAME_LIMIT, name.length
    assert name.end_with?("...")
  end

  test "an unreachable herald is reported and remembered, and the next run picks up where it was" do
    sync
    @herald.respond(503, { "error" => { "code" => "unavailable", "message" => "Full Disk Access" } })
    report = sync.first
    assert_match(/Full Disk Access|503|unavailable/i, report.to_s)
    assert PeopleCursor.sole.last_error.present?

    @herald.message(EUGENE, "hi", at: "2026-10-07T18:00:00Z", from: "+15550001111", name: "Eugene Fox")
    assert_equal 1, sync.first.derived
    assert_nil PeopleCursor.sole.last_error
  end

  test "the job runs at intimate, whatever the caller's clearance" do
    sync
    @herald.message(EUGENE, "hi", at: "2026-10-07T18:00:00Z", from: "+15550001111", name: "Eugene Fox")
    clearance!("household")
    PeopleSyncJob.perform_now
    clearance!("intimate")
    assert_equal 1, PeopleEvent.count
  end
end
