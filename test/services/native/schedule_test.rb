require "test_helper"

# hob.schedule.* (SCHEDULES.md) through the sentinel: an agent asks hob to
# queue missions on a cadence, sees its schedules, and cancels them.
class ScheduleNativeTest < ActiveSupport::TestCase
  setup do
    native_capabilities!
    @muse, _ = agent("muse")
    @skipsy, _ = agent("skipsy")
    policy!(nil, "hob.schedule.*", "allow")
  end

  def submit(capability, arguments = {}, agent: @muse)
    as(agent, realm: agent.max_clearance) { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments) }
  end

  test "sync! registers create, list, cancel" do
    assert_equal %w[act household], Capability.find_by!(name: "hob.schedule.create").slice(:kind, :realm).values
    assert_equal %w[read household], Capability.find_by!(name: "hob.schedule.list").slice(:kind, :realm).values
    assert_equal %w[act household], Capability.find_by!(name: "hob.schedule.cancel").slice(:kind, :realm).values
  end

  test "create schedules a mission for the agent itself; the same name replaces it" do
    request = submit("hob.schedule.create", { "name" => "morning", "cron" => "every day at 7am",
                                              "time_zone" => "America/Los_Angeles", "title" => "plan the day",
                                              "payload" => { "kind" => "plan" } })
    assert_equal "completed", request.status, request.error.to_s
    schedule = Schedule.find(request.result["id"])
    assert_equal [ @muse, @muse, "household", "every day at 7am" ], [ schedule.assignee, schedule.created_by, schedule.realm, schedule.cron ]
    refute request.result["updated"]

    again = submit("hob.schedule.create", { "name" => "morning", "cron" => "0 8 * * *", "title" => "plan the day, later" })
    assert again.result["updated"]
    assert_equal 1, Schedule.count
    assert_equal [ "0 8 * * *", "Etc/UTC" ], schedule.reload.values_at(:cron, :time_zone)
  end

  test "create refuses too often, a stranger, and an assignee who could not see the missions" do
    assert_match(/15 minutes/, submit("hob.schedule.create", { "name" => "x", "cron" => "*/5 * * * *", "title" => "t" }).error)
    assert_match(/no principal nobody/, submit("hob.schedule.create", { "name" => "x", "cron" => "@daily", "title" => "t", "assignee" => "nobody" }).error)
    Principal.create!(name: "kiosk", kind: "worker", max_clearance: "household")
    bonsai, _ = agent("bonsai", clearance: "personal")
    personal = as(bonsai, realm: "personal") do
      Sentinel.submit!(agent: bonsai, capability: "hob.schedule.create",
                       arguments: { "name" => "x", "cron" => "@daily", "title" => "t", "assignee" => "kiosk" })
    end
    assert_match(/above kiosk's clearance/, personal.error)
  end

  test "an agent keeps at most 25" do
    Schedule::MAX_PER_AGENT.times { |i| Schedule.create!(name: "s#{i}", cron: "@daily", assignee: @muse, created_by: @muse, realm: "household", title: "t") }
    assert_match(/already has 25/, submit("hob.schedule.create", { "name" => "one-more", "cron" => "@daily", "title" => "t" }).error)
  end

  test "list shows what the agent made and what is assigned to it, not anyone else's" do
    submit("hob.schedule.create", { "name" => "mine", "cron" => "@daily", "title" => "t" })
    submit("hob.schedule.create", { "name" => "for-muse", "cron" => "@daily", "title" => "t", "assignee" => "muse" }, agent: @skipsy)
    submit("hob.schedule.create", { "name" => "skipsy-own", "cron" => "@daily", "title" => "t" }, agent: @skipsy)

    result = submit("hob.schedule.list").result
    assert_equal %w[for-muse mine], result["schedules"].map { |s| s["name"] }
  end

  test "cancel removes only the agent's own" do
    submit("hob.schedule.create", { "name" => "mine", "cron" => "@daily", "title" => "t" }, agent: @skipsy)
    assert_match(/no schedule named "mine"/, submit("hob.schedule.cancel", { "name" => "mine" }).error)
    assert_equal "mine", submit("hob.schedule.cancel", { "name" => "mine" }, agent: @skipsy).result["cancelled"]
    assert_equal 0, Schedule.count
  end
end
