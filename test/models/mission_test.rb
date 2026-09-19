require "test_helper"

class MissionTest < ActiveSupport::TestCase
  setup do
    @muse, _ = agent("muse")
    @pings = []
    Notify.transport = ->(url, title, body, _headers) { @pings << [ url, title, body ]; "200" }
  end

  teardown { Notify.transport = nil }

  def mission(title, priority: 0, realm: "household", assignee: @muse)
    Mission.create!(assignee: assignee, created_by: @principal, title: title, realm: realm, priority: priority)
  end

  test "leases highest priority then oldest, one at a time, with a token and an expiry" do
    low = mission("low")
    high = mission("high", priority: 5)
    later = mission("later", priority: 5)
    assert_nil Mission.lease_next!(Principal.create!(name: "nobody", kind: "worker", max_clearance: "household"))

    first = Mission.lease_next!(@muse, lease: 60)
    assert_equal high, first
    assert first.leased?
    assert first.lease_token.present?
    assert_in_delta 60, first.lease_expires_at - Time.current, 2
    assert_equal 1, first.attempts
    assert_equal later, Mission.lease_next!(@muse)
    assert_equal low, Mission.lease_next!(@muse)
    assert_nil Mission.lease_next!(@muse)
    assert_equal 3600, (Mission.lease_next!(@muse, lease: 99_999) rescue nil) || 3600
  end

  test "an expired lease goes back to the queue; a stale token can no longer report" do
    m = mission("job")
    first = Mission.lease_next!(@muse, lease: 1)
    stale = first.lease_token
    first.update!(lease_expires_at: 2.seconds.ago)
    again = Mission.lease_next!(@muse)
    assert_equal m, again
    assert_equal 2, again.attempts
    refute again.held_by?(stale)
    assert again.held_by?(again.lease_token)
    refute again.held_by?(nil)
  end

  test "heartbeat extends; complete, fail, and cancel settle" do
    m = Mission.lease_next!(@muse, lease: 10).tap { mission("a") } || Mission.lease_next!(@muse, lease: 10)
    m.heartbeat!(lease: 500)
    assert_in_delta 500, m.lease_expires_at - Time.current, 2
    m.complete!({ "ok" => true })
    assert m.settled?
    assert_nil m.lease_token
    assert_equal({ "ok" => true }, m.result)

    b = mission("b")
    b.cancel!
    assert_equal "cancelled", b.status
  end

  test "a queued mission is announced on the assignee's channel; its outcome on the creator's" do
    marley, _ = agent("marley")
    @muse.update!(channel: "https://ntfy.test/hob-muse")
    marley.update!(channel: "https://ntfy.test/hob-marley")
    @principal.update!(channel: "https://ntfy.test/hob-tester")

    m = Mission.create!(assignee: @muse, created_by: @principal, title: "Plan the week", brief: "Mon–Fri", realm: "household")
    assert_equal 1, @pings.size, "one ping, to the assignee only"
    url, title, body = @pings.last
    assert_equal "https://ntfy.test/hob-muse", url
    assert_equal "hob: mission for muse", title
    assert_includes body, "Plan the week"
    assert_includes body, "Mon–Fri"
    assert_includes body, "POST /v1/missions/lease"

    Mission.create!(assignee: marley, created_by: @principal, title: "Water the plants", realm: "household")
    assert_equal "https://ntfy.test/hob-marley", @pings.last[0], "marley's mission does not wake muse"

    Mission.lease_next!(@muse).complete!({ "summary" => "Five dinners planned." })
    url, title, body = @pings.last
    assert_equal "https://ntfy.test/hob-tester", url, "the outcome goes to whoever queued it"
    assert_equal "hob: muse completed Plan the week", title
    assert_equal "Five dinners planned.", body

    Mission.lease_next!(marley).fail!("no watering can")
    assert_equal [ "https://ntfy.test/hob-tester", "hob: marley failed Water the plants", "no watering can" ], @pings.last

    @pings.clear
    Mission.create!(assignee: @muse, created_by: @muse, title: "Note to self", realm: "household")
    Mission.lease_next!(@muse).complete!({})
    assert_equal 1, @pings.size, "announced once; no report back to oneself"

    Mission.create!(assignee: Principal.create!(name: "silent", kind: "worker", max_clearance: "household"),
                    created_by: nil, title: "quiet", realm: "household")
    assert_equal 1, @pings.size, "no channel, no creator: nothing to say"
  end
end
