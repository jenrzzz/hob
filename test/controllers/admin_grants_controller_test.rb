require "test_helper"

# Viewing and editing capability grants (sentinel_policies) per agent, and
# their guidance history — the admin path to the same audited edit a
# petition's approval writes through (SentinelPolicy#update_guidance!).
class AdminGrantsControllerTest < ActionDispatch::IntegrationTest
  setup do
    admin_signing_in!
    @muse, = agent("muse")
  end

  teardown { admin_signed_out! }

  test "signed out, the grants page sends you to sign in" do
    get "/admin/grants"
    assert_redirected_to "/login"
  end

  test "the index lists every agent's grants, filterable by agent" do
    rule = policy!(@muse, "browse.open", "review", guidance: "Amazon order and product pages.")
    skribe, = agent("skribe")
    policy!(skribe, "hob.usage", "allow")
    admin_sign_in

    get "/admin/grants"
    assert_response :ok
    assert_select "table td", "muse"
    assert_select "table td", "skribe"
    assert_select "table a[href=?]", admin_grant_path(rule), "Edit"

    get "/admin/grants", params: { agent: "muse" }
    assert_select "table td", "muse"
    assert_select "table td", { count: 0, text: "skribe" }
  end

  test "a grant's show page holds its effect, constraints, and a form to edit guidance" do
    rule = policy!(@muse, "browse.open", "review", guidance: "Amazon order and product pages.",
                   constraints: { "url" => { "pattern" => "amazon" } }, limits: { "per_day" => 20 })
    admin_sign_in

    get "/admin/grants/#{rule.id}"
    assert_response :ok
    assert_select "h1", /muse.*browse.open/
    assert_select ".tag", "review"
    assert_select "pre", /per_day/
    assert_select "textarea", "Amazon order and product pages."
  end

  test "editing guidance writes through the audited path, keeps the effect, and shows the history" do
    rule = policy!(@muse, "browse.open", "review", guidance: "Amazon order and product pages for YNAB bookkeeping.")
    admin_sign_in

    post "/admin/grants/#{rule.id}",
         params: { guidance: "Amazon pages, and read-only parcel tracking on ups.com, fedex.com, usps.com.",
                   rationale: "widened after the petition was approved" }
    assert_redirected_to "/admin/grants/#{rule.id}"
    follow_redirect!
    assert_select ".flash.notice", /Updated guidance/

    rule.reload
    assert_equal "review", rule.effect
    assert_equal "Amazon pages, and read-only parcel tracking on ups.com, fedex.com, usps.com.", rule.guidance

    change = rule.guidance_changes.sole
    assert_equal "admin", change.source
    assert_equal "human", change.decided_by
    assert_equal @principal, change.decider
    assert_equal "widened after the petition was approved", change.rationale
    assert_equal "Amazon order and product pages for YNAB bookkeeping.", change.old_guidance

    assert_select "table td", "admin"
    assert_select "table td", @principal.name
  end

  test "writing back the same guidance is a no-op: no new history row" do
    rule = policy!(@muse, "browse.open", "review", guidance: "Amazon order and product pages.")
    admin_sign_in

    assert_no_difference -> { GuidanceChange.count } do
      post "/admin/grants/#{rule.id}", params: { guidance: "Amazon order and product pages." }
    end
  end
end
