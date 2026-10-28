require "test_helper"

# The red-branch watch (SCHEDULES.md, "Upkeep"): a kept repo whose branch
# failed its checks gets one forge fix per commit.
class UpkeepChecksTest < ActiveSupport::TestCase
  SHA = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678".freeze

  setup do
    @forge, _ = forge!
    @schedule = schedule!("jenrzzz/airing", "trunk")
    @runs = [
      { "name" => "test", "status" => "completed", "conclusion" => "failure",
        "details_url" => "https://github.com/jenrzzz/airing/actions/runs/11/job/22",
        "output" => { "title" => "1 failing test", "summary" => nil } },
      { "name" => "lint", "status" => "completed", "conclusion" => "success" },
      { "name" => "deploy", "status" => "completed", "conclusion" => "cancelled" }
    ]
    @statuses = []
    @paths = []
    @sha = SHA
  end

  def schedule!(repo, branch, scope: "minor", enabled: true)
    Schedule.create!(created_by: nil, name: "upkeep-#{repo.split('/').last}#{'-major' if scope == 'major'}", cron: "0 3 * * 1",
                     time_zone: "Etc/UTC", assignee: @forge, realm: "household", title: "upkeep: #{repo}", enabled: enabled,
                     payload: { "kind" => "forge.upkeep", "repo" => repo, "branch" => branch, "scope" => scope }.compact)
  end

  def github
    Upkeep::Checks::Client.new(transport: lambda do |path|
      @paths << path
      case path
      when %r{\A/repos/[^/]+/[^/]+\z} then { "default_branch" => "main" }
      when %r{\A/repos/jenrzzz/gone/} then raise Upkeep::Checks::Error, "HTTP 404"
      when %r{/commits/[^/]+/status\z} then { "sha" => @sha, "state" => "failure", "statuses" => @statuses }
      when %r{/commits/#{@sha}/check-runs} then { "check_runs" => @runs }
      else raise Upkeep::Checks::Error, "HTTP 404 #{path}"
      end
    end)
  end

  def watch(**opts) = Upkeep::Checks.watch!(github: github, **opts)

  test "a red head gets a fix mission for the forge, under the repo's weekly schedule" do
    report = watch
    assert_equal({ "jenrzzz/airing" => "red" }, report.checked)
    assert_equal [ "jenrzzz/airing" ], report.queued

    mission = Mission.sole
    assert_equal [ @forge, @schedule, nil, "household", 0, "upkeep: fix jenrzzz/airing" ],
                 [ mission.assignee, mission.schedule, mission.created_by, mission.realm, mission.priority, mission.title ]
    assert_equal({ "kind" => "forge.upkeep", "repo" => "jenrzzz/airing", "branch" => "trunk", "scope" => "fix", "sha" => SHA,
                   "failures" => [ { "name" => "test", "url" => "https://github.com/jenrzzz/airing/actions/runs/11/job/22",
                                     "summary" => "1 failing test" } ] },
                 mission.payload, "cancelled is not a failure")
    assert_match(/trunk failed test at a1b2c3d/, mission.brief)
    assert_includes @paths, "/repos/jenrzzz/airing/commits/trunk/status"
    assert_nil @schedule.reload.last_mission_id, "the schedule's own clock is untouched"
  end

  test "one attempt per commit, one fix at a time per repo" do
    watch
    assert_empty watch.queued, "the open fix is the answer"
    Mission.sole.update!(status: "failed")
    assert_empty watch.queued, "this commit was tried"

    @sha = "f" * 40
    assert_equal [ "jenrzzz/airing" ], watch.queued, "a newer red commit is a new attempt"
    assert_equal [ SHA, @sha ], Mission.order(:created_at).map { |m| m.payload["sha"] }
  end

  test "pending, green, and silent heads are left alone; so is a dry run" do
    @runs << { "name" => "system", "status" => "in_progress", "conclusion" => nil }
    assert_equal "pending", watch.checked["jenrzzz/airing"], "red waits until every check has finished"
    @runs.reject! { |r| r["conclusion"] != "success" }
    assert_equal "green", watch.checked["jenrzzz/airing"]
    @runs.clear
    assert_equal "none", watch.checked["jenrzzz/airing"]
    @statuses << { "context" => "ci/circle", "state" => "error", "target_url" => "https://circleci.com/x", "description" => "broke" }
    report = watch(dry_run: true)
    assert_equal [ "jenrzzz/airing" ], report.queued, "a failed commit status counts"
    assert_equal 0, Mission.count
  end

  test "only enabled weekly schedules are watched, and an unreadable repo does not stop the rest" do
    @schedule.update!(enabled: false)
    schedule!("jenrzzz/airing", "trunk", scope: "major")
    assert_empty watch.checked

    @schedule.update!(enabled: true)
    schedule!("jenrzzz/gone", nil).update!(name: "upkeep-gone")
    @runs.reject! { |r| r["conclusion"] != "success" }
    report = watch
    assert_equal({ "jenrzzz/airing" => "green" }, report.checked)
    assert_equal({ "jenrzzz/gone" => "HTTP 404" }, report.errors)
  end

  test "a schedule with no branch reads the repo's default" do
    @schedule.update!(payload: @schedule.payload.except("branch"))
    watch
    assert_includes @paths, "/repos/jenrzzz/airing/commits/main/status"
    assert_equal "main", Mission.sole.payload["branch"]
  end

  test "a fix that is waiting on review reports to the household; one that found the branch moved does not" do
    watch
    mission = Mission.sole
    sent = []
    Notify.transport = ->(url, title, *) { sent << title if url == "https://ntfy.example/house"; "200" }
    ENV["HOB_NOTIFY_URL"] = "https://ntfy.example/house"
    mission.update!(status: "leased")
    mission.complete!({ "status" => "moved", "summary" => "moved on" })
    assert_empty sent
    mission.update!(status: "leased")
    mission.complete!({ "status" => "review", "notify" => true, "summary" => "jenrzzz/airing: PR" })
    assert_equal [ "hob: forge completed upkeep: fix jenrzzz/airing" ], sent
  ensure
    Notify.transport = nil
    ENV.delete("HOB_NOTIFY_URL")
  end

  test "the job is quiet without a token" do
    ENV.delete("HOB_GITHUB_TOKEN")
    UpkeepChecksJob.perform_now
    assert_equal 0, Mission.count
  end
end
