require "test_helper"

# The rules over HTTP (SENTINEL.md, "Policies"): people only. Updating
# guidance writes through the same audited path (GuidanceChange) as a
# petition's approval and the admin UI, no matter which door it came
# through; effect, constraints, and limits stay unaudited config.
class PoliciesControllerTest < ActionDispatch::IntegrationTest
  setup { @muse, = agent("muse") }

  test "an agent cannot manage policies" do
    _, token = agent("muse2")
    post "/v1/sentinel/policies", params: { capability: "hob.usage", effect: "allow" },
         headers: { "Authorization" => "Bearer #{token}" }, as: :json
    assert_response :forbidden
  end

  test "updating guidance logs who, when, old and new text, and leaves the effect alone" do
    rule = policy!(@muse, "browse.open", "review", guidance: "Amazon order and product pages for YNAB bookkeeping.")

    patch "/v1/sentinel/policies/#{rule.id}",
          params: { guidance: "Amazon pages, and read-only parcel tracking on ups.com, fedex.com, usps.com.",
                    rationale: "widened per the approved petition" },
          headers: auth, as: :json
    assert_response :ok
    assert_equal "review", body["effect"]
    assert_equal "Amazon pages, and read-only parcel tracking on ups.com, fedex.com, usps.com.", body["guidance"]

    rule.reload
    assert_equal "review", rule.effect
    change = rule.guidance_changes.sole
    assert_equal "admin", change.source
    assert_equal "human", change.decided_by
    assert_equal @principal, change.decider
    assert_equal "Amazon order and product pages for YNAB bookkeeping.", change.old_guidance
    assert_equal "widened per the approved petition", change.rationale
  end

  test "updating effect alongside guidance changes both, but only guidance is audited" do
    rule = policy!(@muse, "hob.usage", "review", guidance: "old")
    patch "/v1/sentinel/policies/#{rule.id}", params: { effect: "allow", guidance: "new" }, headers: auth, as: :json
    assert_response :ok
    rule.reload
    assert_equal "allow", rule.effect
    assert_equal "new", rule.guidance
    assert_equal 1, rule.guidance_changes.count
  end

  test "updating effect without guidance is not audited" do
    rule = policy!(@muse, "hob.usage", "review", guidance: "old")
    patch "/v1/sentinel/policies/#{rule.id}", params: { effect: "allow" }, headers: auth, as: :json
    assert_response :ok
    assert_equal "allow", rule.reload.effect
    assert_equal 0, rule.guidance_changes.count
  end

  test "writing back the same guidance over the API is a no-op" do
    rule = policy!(@muse, "hob.usage", "review", guidance: "same")
    assert_no_difference -> { GuidanceChange.count } do
      patch "/v1/sentinel/policies/#{rule.id}", params: { guidance: "same" }, headers: auth, as: :json
    end
  end
end
