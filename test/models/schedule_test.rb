require "test_helper"

# hob's clock (SCHEDULES.md): a schedule queues its mission when due, moves
# on, never stacks, never catches up, and says so when its worker is stuck.
class ScheduleTest < ActiveSupport::TestCase
  setup do
    @worker = Principal.create!(name: "upkeep", kind: "worker", max_clearance: "personal")
    @pings = []
    Notify.transport = ->(url, title, body, _headers) { @pings << [ url, title, body ]; "200" }
    ENV["HOB_NOTIFY_URL"] = "https://ntfy.test/hob"
  end

  teardown do
    Notify.transport = nil
    ENV.delete("HOB_NOTIFY_URL")
  end

  def schedule(name = "daily", cron: "0 7 * * *", **attrs)
    Schedule.create!(name: name, cron: cron, assignee: @worker, realm: "household", title: "do the thing",
                     payload: { "kind" => "thing" }, **attrs)
  end

  test "plans its first firing in its own time zone" do
    travel_to Time.utc(2026, 10, 1, 12, 0) do
      assert_equal Time.utc(2026, 10, 2, 7), schedule("utc").next_fire_at
      assert_equal Time.utc(2026, 10, 1, 14), schedule("pacific", time_zone: "America/Los_Angeles").next_fire_at
      assert_equal Time.utc(2026, 10, 2, 7), schedule("words", cron: "every day at 7am").next_fire_at
    end
  end

  test "rejects what it cannot run" do
    bad = Schedule.new(name: "Bad Name", cron: "whenever", time_zone: "Mars/Olympus", assignee: @worker, realm: "intimate", title: "x")
    refute bad.valid?
    assert bad.errors[:name].any?
    assert_match(/fugit/, bad.errors[:cron].first)
    assert bad.errors[:time_zone].any?
    assert_match(/above upkeep's clearance/, bad.errors[:realm].first)
  end

  test "an agent's schedule fires at most every 15 minutes; a person's may fire every minute" do
    muse, _ = agent("muse")
    refute Schedule.new(name: "busy", cron: "*/5 * * * *", assignee: @worker, realm: "household", title: "x", created_by: muse).valid?
    assert Schedule.new(name: "calm", cron: "*/15 * * * *", assignee: @worker, realm: "household", title: "x", created_by: muse).valid?
    assert Schedule.new(name: "busy", cron: "* * * * *", assignee: @worker, realm: "household", title: "x", created_by: @principal).valid?
  end

  test "names are unique per creator, hob's own included" do
    schedule("daily")
    assert_raises(ActiveRecord::RecordInvalid) { schedule("daily") }
    assert schedule("daily", created_by: @principal).persisted?
  end

  test "tick queues the mission once when due and moves on; nothing before then" do
    s = travel_to(Time.utc(2026, 10, 1, 6, 0)) { schedule }
    assert_empty Schedule.tick!(now: Time.utc(2026, 10, 1, 6, 59))

    fired = Schedule.tick!(now: Time.utc(2026, 10, 1, 7, 0, 30))
    assert_equal 1, fired.size
    mission = fired.first.last
    assert_equal [ @worker, "do the thing", { "kind" => "thing" }, "household", s.id ],
                 [ mission.assignee, mission.title, mission.payload, mission.realm, mission.schedule_id ]
    s.reload
    assert_equal [ 1, mission.id, Time.utc(2026, 10, 2, 7) ], [ s.fired_count, s.last_mission_id, s.next_fire_at ]
    assert_empty Schedule.tick!(now: Time.utc(2026, 10, 1, 7, 1))
  end

  test "a long outage fires once, not once per missed day" do
    travel_to(Time.utc(2026, 10, 1, 6, 0)) { schedule }
    fired = Schedule.tick!(now: Time.utc(2026, 10, 5, 12, 0))
    assert_equal 1, fired.size
    assert_equal Time.utc(2026, 10, 6, 7), Schedule.first.next_fire_at
  end

  test "skips while the last mission is open, pings once per streak, fires again once it settles" do
    s = travel_to(Time.utc(2026, 10, 1, 6, 0)) { schedule }
    first = Schedule.tick!(now: Time.utc(2026, 10, 1, 7)).first.last
    @pings.clear

    assert_equal [ [ s, nil ] ], Schedule.tick!(now: Time.utc(2026, 10, 2, 7))
    assert_equal [ [ s, nil ] ], Schedule.tick!(now: Time.utc(2026, 10, 3, 7))
    s.reload
    assert_equal [ 1, 2 ], [ s.fired_count, s.skipped_count ]
    assert_equal 1, @pings.count { |_, title, _| title.include?("daily skipped") }
    assert_match(/#{first.id}/, @pings.find { |_, title, _| title.include?("skipped") }[2])

    first.update!(status: "completed")
    second = Schedule.tick!(now: Time.utc(2026, 10, 4, 7)).first.last
    assert second
    refute_equal first, second

    @pings.clear
    Schedule.tick!(now: Time.utc(2026, 10, 5, 7))
    assert_equal 1, @pings.count { |_, title, _| title.include?("daily skipped") }, "a new streak pings again"
  end

  test "disabled schedules have no next firing and never fire; enabling plans again" do
    s = schedule(enabled: false)
    assert_nil s.next_fire_at
    assert_empty Schedule.tick!(now: 2.days.from_now)
    s.update!(enabled: true)
    assert s.next_fire_at
  end

  test "the tick job runs at the top clearance as hob" do
    travel_to(Time.utc(2026, 10, 1, 6, 0)) { schedule(realm: "personal") }
    clearance!("household")
    travel_to(Time.utc(2026, 10, 1, 7, 0, 5)) { ScheduleTickJob.perform_now }
    clearance!("intimate")
    assert_equal 1, Mission.where(realm: "personal").count
  end

  test "schedules are realm-scoped" do
    schedule("private", realm: "personal")
    clearance!("household")
    assert_empty Schedule.where(name: "private")
  end
end

class ScheduledMissionReportTest < ActiveSupport::TestCase
  setup do
    @worker = Principal.create!(name: "upkeep", kind: "worker", max_clearance: "household")
    @pings = []
    Notify.transport = ->(url, title, body, _headers) { @pings << [ url, title, body ]; "200" }
    ENV["HOB_NOTIFY_URL"] = "https://ntfy.test/hob"
    @schedule = Schedule.create!(name: "upkeep-x", cron: "@weekly", assignee: @worker, realm: "household", title: "upkeep: x")
  end

  teardown do
    Notify.transport = nil
    ENV.delete("HOB_NOTIFY_URL")
  end

  def reports = @pings.reject { |_, title, _| title.include?("mission for") }

  test "hob's own schedules report to the household: failures always, completions only when the worker asks" do
    @schedule.fire!.complete!({ "summary" => "x: merged #1", "notify" => false })
    assert_empty reports

    @schedule.fire!.complete!({ "summary" => "x: #2 needs review: major versions: rails", "notify" => true })
    assert_equal [ [ "https://ntfy.test/hob", "hob: upkeep completed upkeep: x", "x: #2 needs review: major versions: rails" ] ], reports

    @pings.clear
    @schedule.fire!.fail!("Refused: needs Ruby 4.0.6")
    assert_equal [ "hob: upkeep failed upkeep: x" ], reports.map { |_, title, _| title }
  end

  test "a mission nobody queued and no schedule fired still reports to no one" do
    Mission.create!(assignee: @worker, title: "loose", realm: "household").complete!({ "notify" => true })
    assert_empty reports
  end
end
