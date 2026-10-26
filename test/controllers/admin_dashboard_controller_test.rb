require "test_helper"

# The admin home: hob at a glance, with what is waiting on a person first.
class AdminDashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
    admin_signing_in!
    native_capabilities!
    @muse, @agent_token = agent("muse")
    Notify.transport = ->(*) { }
  end

  teardown do
    admin_signed_out!
    Notify.transport = nil
  end

  test "an empty household renders" do
    admin_sign_in
    get "/admin"
    assert_response :ok
    assert_select "#waiting", /Nothing is waiting/
    assert_select "#missions", /Nothing queued/
  end

  test "shows what is waiting, the work in hand, and what it cost" do
    policy!(@muse, "hob.usage", "confirm")
    post "/v1/sentinel/requests", params: { capability: "hob.usage", arguments: {}, reason: "budget <check>" },
         headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
    assert_equal "pending", body["status"]
    request_id = body["id"]
    Mission.create!(assignee: @muse, title: "Water the plants", realm: "household")
    UsageEvent.record(principal: @principal, surface: "chatelaine", model: "claude-sonnet-5", status: "success",
                      units: { "input_tokens" => 1200, "output_tokens" => 300 }, cost: 0.42)
    BoardPost.create!(thread_id: "t", thread_slug: "plants", thread_topic: "Plants", realm: "household", body: "on it",
                      sender_agent: @muse, surface: "muse")

    admin_sign_in
    get "/admin"
    assert_response :ok
    assert_select "#waiting .badge", "1"
    assert_select "#waiting a[href='/admin/sentinel#request-#{request_id}']", /hob\.usage/
    assert_includes response.body, "budget &lt;check&gt;"
    assert_select "#missions", /Water the plants/
    assert_select "#usage", /\$0\.42/
    assert_select "#usage code", "claude-sonnet-5"
    assert_select "#board", /on it/
    assert_select "#agents a", "muse"
  end

  test "shows the ward's watch, the clock, and the person's own situation" do
    check = WardCheck.create!(slug: "exposure", description: "the audit", interval_seconds: 3600, grace_seconds: 600)
    check.update_columns(created_at: 1.day.ago)
    now = Time.current
    WardFinding.create!(check: check, fingerprint: "f1", level: "fail", subject: "port 22 open", message: "ssh on the WAN",
                        first_seen_at: now, last_seen_at: now)
    WardThreat.create!(kind: "cve", title: "CVE-2026-10001 in caddy", cve_ids: [ "CVE-2026-10001" ], status: "exposed", assessed_severity: "high",
                       proposals: [ { "id" => "p1", "tier" => 2, "title" => "Upgrade caddy", "state" => "proposed" } ])
    Schedule.create!(name: "morning-brief", cron: "0 7 * * *", assignee: @muse, realm: "household", title: "brief")
    writer = Situation::Writer.new(principal: @principal, surface: "test", clearance: "intimate")
    Situation.observe(person: @principal, observations: [ { "kind" => "location", "value" => { "place" => "the garden" } } ], by: writer)

    admin_sign_in
    get "/admin"
    assert_response :ok
    assert_select "#ward .tag.bad", "1 stale"
    assert_select "#ward", /port 22 open/
    assert_select "#threats", /CVE-2026-10001 in caddy/
    assert_select "#waiting", /Upgrade caddy/
    assert_select "#schedules", /morning-brief/
    assert_select "#situation", /location: the garden/
  end
end
