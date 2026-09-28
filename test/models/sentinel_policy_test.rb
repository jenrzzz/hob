require "test_helper"

# A sentinel_policies row is a grant: (agent, capability) -> effect, plus the
# guidance a reviewer is told (SENTINEL.md, "Policies"). update_guidance! is
# the one audited way to change that text after the grant (a petition's
# approval, or an admin edit) — GuidanceChange is the trail.
class SentinelPolicyTest < ActiveSupport::TestCase
  setup do
    @muse, = agent("muse")
    @rule = policy!(@muse, "browse.open", "review", guidance: "Amazon order and product pages for bookkeeping.")
  end

  test "updating guidance logs the change and leaves the effect alone" do
    change = nil
    assert_difference -> { GuidanceChange.count }, 1 do
      change = @rule.update_guidance!("Amazon pages, and read-only parcel tracking on ups.com, fedex.com, usps.com.",
                                      source: "petition", decided_by: "steward", rationale: "widened per petition")
    end
    @rule.reload
    assert_equal "Amazon pages, and read-only parcel tracking on ups.com, fedex.com, usps.com.", @rule.guidance
    assert_equal "review", @rule.effect, "guidance changes never touch the effect"

    logged = GuidanceChange.last
    assert_equal @rule, change
    assert_equal @rule, logged.sentinel_policy
    assert_equal "petition", logged.source
    assert_equal "steward", logged.decided_by
    assert_nil logged.decider
    assert_equal "Amazon order and product pages for bookkeeping.", logged.old_guidance
    assert_equal "Amazon pages, and read-only parcel tracking on ups.com, fedex.com, usps.com.", logged.new_guidance
    assert_equal "widened per petition", logged.rationale
  end

  test "an admin edit is logged with the deciding person and the admin source" do
    jenner = Principal.create!(name: "jenner", kind: "human", max_clearance: "intimate")
    @rule.update_guidance!("Narrower: order pages only.", source: "admin", decided_by: "human", decider: jenner)
    logged = GuidanceChange.last
    assert_equal "admin", logged.source
    assert_equal "human", logged.decided_by
    assert_equal jenner, logged.decider
  end

  test "writing back the same text is a no-op, logged nowhere" do
    assert_no_difference -> { GuidanceChange.count } do
      @rule.update_guidance!(@rule.guidance, source: "admin", decided_by: "human")
    end
  end

  test "clearing guidance to blank is itself a logged change" do
    assert_difference -> { GuidanceChange.count }, 1 do
      @rule.update_guidance!("", source: "admin", decided_by: "human")
    end
    assert_nil @rule.reload.guidance
    assert_nil GuidanceChange.last.new_guidance
  end

  test "only a person can be the decider on a guidance change" do
    change = GuidanceChange.new(sentinel_policy: @rule, source: "admin", decided_by: "human", decider: @muse,
                                new_guidance: "x")
    refute change.valid?
    assert_match(/must be a person/, change.errors[:decider].to_sentence)
  end

  test "a policy cannot be deleted out from under its guidance history" do
    @rule.update_guidance!("changed", source: "admin", decided_by: "human")
    assert_raises(ActiveRecord::DeleteRestrictionError) { @rule.destroy! }
  end
end
