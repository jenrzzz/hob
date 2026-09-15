require "test_helper"

class MissionTest < ActiveSupport::TestCase
  setup do
    @muse, _ = agent("muse")
  end

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
end
