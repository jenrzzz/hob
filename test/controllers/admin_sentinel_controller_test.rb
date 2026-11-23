require "test_helper"

# Deciding what the sentinel holds for a person, from the admin pages.
class AdminSentinelControllerTest < ActionDispatch::IntegrationTest
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

  def held_request
    policy!(@muse, "hob.usage", "confirm")
    post "/v1/sentinel/requests", params: { capability: "hob.usage", arguments: { since: "2026-09-01" }, reason: "budget" },
         headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
    assert_equal "pending", body["status"]
    SentinelRequest.find(body["id"])
  end

  def pending_petition
    Petition.create!(principal: @muse, want: "see my spend", capability_name: "hob.usage", effect: "allow",
                     realm: "household", surface: "muse", status: "pending", action: "refer", rationale: "not in its charter")
  end

  test "signed out, the sentinel page sends you to sign in" do
    get "/admin/sentinel"
    assert_redirected_to "/login"
  end

  test "a held request shows with its arguments, and allowing it runs it" do
    request = held_request
    admin_sign_in
    get "/admin/sentinel"
    assert_response :ok
    assert_select "#request-#{request.id} h2", /muse asks for hob.usage/
    assert_select "#request-#{request.id} pre", /2026-09-01/
    assert_select "header .badge", "1"

    post "/admin/sentinel/requests/#{request.id}/decide", params: { decision: "allow", rationale: "fine" }
    assert_redirected_to "/admin/sentinel"
    request.reload
    assert_equal [ "allow", "human", @principal, "fine" ], [ request.decision, request.decided_by, request.decider, request.rationale ]
    assert_equal "completed", request.status

    post "/admin/sentinel/requests/#{request.id}/decide", params: { decision: "deny" }
    follow_redirect!
    assert_select ".flash.alert", /not pending/
  end

  test "a held ward.threat.accept_risk shows the threat it acts on, escaped, and allowing it accepts as the person" do
    skipsy, token = agent("skipsy", clearance: "personal")
    policy!(skipsy, "ward.threat.accept_risk", "confirm")
    threat = WardThreat.create!(kind: "cve", title: "PHP2Shell <script>x</script>", cve_ids: [ "CVE-2026-109618" ], status: "exposed",
                                assessed_severity: "high", affected: [ { "asset" => "a", "name" => "coolify", "component" => "php", "verdict" => "unknown" } ])
    post "/v1/sentinel/requests", params: { capability: "ward.threat.accept_risk", arguments: { threat: threat.id, reason: "behind Authelia" } },
         headers: { "Authorization" => "Bearer #{token}" }, as: :json
    request = SentinelRequest.find(body["id"])
    assert_equal "pending", request.status

    admin_sign_in
    get "/admin/sentinel"
    assert_select "#request-#{request.id} dd", /PHP2Shell <script>x<\/script>/
    assert_select "#request-#{request.id} script", false, "a reporter's title is text, never markup"
    assert_select "#request-#{request.id} dd", /coolify · php · unknown/
    assert_select "#request-#{request.id} dd", /re-surfaces every 30 days/

    post "/admin/sentinel/requests/#{request.id}/decide", params: { decision: "allow" }
    threat.reload
    assert_equal [ "accepted_risk", @principal, "behind Authelia" ], [ threat.status, threat.accepted_by, threat.accepted_reason ]
  end

  test "denying a request" do
    request = held_request
    admin_sign_in
    post "/admin/sentinel/requests/#{request.id}/decide", params: { decision: "deny" }
    assert_equal "denied", request.reload.status
  end

  test "granting a petition at a chosen effect writes the policy" do
    petition = pending_petition
    admin_sign_in
    get "/admin/sentinel"
    assert_select "#petition-#{petition.id} p", "see my spend"

    post "/admin/sentinel/petitions/#{petition.id}/decide", params: { decision: "grant", capability: "hob.usage", effect: "review" }
    assert_redirected_to "/admin/sentinel"
    petition.reload
    assert_equal [ "granted", @principal ], [ petition.status, petition.decider ]
    assert_equal "review", SentinelPolicy.find_by!(principal: @muse, capability: "hob.usage").effect

    get "/admin/sentinel"
    assert_select "#history-rows td", /petition for hob.usage/
    assert_select "#history-rows .tag", "granted"
  end

  test "approving a petition to widen an already-held capability's guidance shows the current grant and logs the change" do
    rule = policy!(@muse, "browse.open", "review", guidance: "Amazon order and product pages for YNAB bookkeeping.")
    petition = Petition.create!(principal: @muse, want: "track packages on carrier sites", capability_name: "browse.open",
                                effect: "review", realm: "household", surface: "muse", status: "pending", action: "refer",
                                rationale: "referred by the steward")
    admin_sign_in
    get "/admin/sentinel"
    assert_select "#petition-#{petition.id} dd", /review since.*Amazon order and product pages/m
    assert_select "#petition-#{petition.id} textarea", "Amazon order and product pages for YNAB bookkeeping."

    post "/admin/sentinel/petitions/#{petition.id}/decide",
         params: { decision: "grant", capability: "browse.open",
                   guidance: "Amazon order and product pages, and read-only parcel tracking on ups.com, fedex.com, usps.com.",
                   rationale: "widened for parcel tracking" }
    assert_redirected_to "/admin/sentinel"
    petition.reload
    assert_equal "granted", petition.status
    rule.reload
    assert_equal "review", rule.effect, "the guidance edit does not change the effect"
    assert_equal "Amazon order and product pages, and read-only parcel tracking on ups.com, fedex.com, usps.com.", rule.guidance

    change = rule.guidance_changes.last
    assert_equal "petition", change.source
    assert_equal "human", change.decided_by
    assert_equal @principal, change.decider
    assert_equal petition, change.petition
  end

  test "a held, bounded grant shows its bounds, is not granted unchanged, and is widened from the constraints box" do
    rule = policy!(@muse, "hob.usage", "review", constraints: { "days" => { "max" => 7 } })
    petition = pending_petition
    admin_sign_in
    get "/admin/sentinel"
    assert_select "#petition-#{petition.id} dd", /bounded: days at most 7/
    assert_select "#petition-#{petition.id} textarea[name=constraints]", text: /"days":\{"max":7\}/

    post "/admin/sentinel/petitions/#{petition.id}/decide", params: { decision: "grant", constraints: rule.constraints.to_json }
    follow_redirect!
    assert_select ".flash.alert", /bounded \(days at most 7\) and granting this would change nothing/
    assert_equal "pending", petition.reload.status

    post "/admin/sentinel/petitions/#{petition.id}/decide", params: { decision: "grant", constraints: "{not json" }
    follow_redirect!
    assert_select ".flash.alert", /constraints is not JSON/

    post "/admin/sentinel/petitions/#{petition.id}/decide", params: { decision: "grant", constraints: '{"days":{"max":30}}' }
    assert_equal "granted", petition.reload.status
    assert_equal({ "days" => { "max" => 30 } }, rule.reload.constraints)
  end

  test "a bad decision is refused with a message" do
    petition = pending_petition
    admin_sign_in
    post "/admin/sentinel/petitions/#{petition.id}/decide", params: { decision: "grant", effect: "deny" }
    follow_redirect!
    assert_select ".flash.alert", /effect must be one of/
    assert_equal "pending", petition.reload.status
  end

  test "a person sees only what their clearance reaches" do
    petition = pending_petition
    petition.update_columns(realm: "intimate")
    @principal.update!(max_clearance: "personal")
    admin_sign_in
    get "/admin/sentinel"
    assert_select "#petition-#{petition.id}", 0
  end

  def settled_request(at:, capability: "hob.usage", status: "completed", principal: @muse, reason: "budget")
    SentinelRequest.create!(principal: principal, capability: Capability.find_by!(name: capability), arguments: { "since" => "2026-09-01" },
                            reason: reason, surface: "muse", realm: "household", status: status, decision: status == "denied" ? "deny" : "allow",
                            decided_by: "reviewer", rationale: "within its charter", created_at: at, result: { "spent" => 12 })
  end

  test "the history pages through every row, newest first, without repeats or gaps" do
    base = Time.utc(2026, 11, 1, 12)
    requests = Array.new(Admin::SentinelController::HISTORY_PAGE + 7) { |i| settled_request(at: base + i.minutes) }
    petition = pending_petition.tap { |p| p.update_columns(created_at: base + 30.minutes + 30.seconds, status: "granted") }
    admin_sign_in

    get "/admin/sentinel"
    assert_response :ok
    first = css_select("#history-rows tr").size
    assert_equal Admin::SentinelController::HISTORY_PAGE, first
    assert_select "#history-rows tr:first-child a[href='/admin/sentinel/requests/#{requests.last.id}']"
    older = css_select("#history-more a[data-next]").first["href"]

    get older.sub("#history", "") + "&rows=1"
    assert_response :ok
    assert_no_match(/<html/, response.body, "the next page is just its rows")
    seen = css_select("tbody tr a").map { |a| a["href"] }
    assert_equal 8, seen.size
    assert_includes seen, "/admin/sentinel/requests/#{requests.first.id}"
    assert_select "#history-more", /That's everything/

    all = requests.map { |r| "/admin/sentinel/requests/#{r.id}" } + [ "/admin/sentinel/petitions/#{petition.id}" ]
    get "/admin/sentinel"
    seen += css_select("#history-rows tr td:nth-child(3) a:first-child").map { |a| a["href"] }
    assert_equal all.sort, seen.sort
  end

  test "the history filters by agent, capability, status and kind" do
    skipsy, = agent("skipsy")
    mine = settled_request(at: 2.hours.ago)
    theirs = settled_request(at: 1.hour.ago, principal: skipsy, status: "denied")
    petition = pending_petition
    admin_sign_in

    get "/admin/sentinel", params: { agent: "skipsy" }
    assert_select "#history-rows a[href='/admin/sentinel/requests/#{theirs.id}']"
    assert_select "#history-rows a[href='/admin/sentinel/requests/#{mine.id}']", 0

    get "/admin/sentinel", params: { status: "completed" }
    assert_select "#history-rows a[href='/admin/sentinel/requests/#{mine.id}']"
    assert_select "#history-rows a[href='/admin/sentinel/requests/#{theirs.id}']", 0

    get "/admin/sentinel", params: { kind: "petitions", capability: "hob.usage" }
    assert_select "#history-rows a[href='/admin/sentinel/petitions/#{petition.id}']"
    assert_select "#history-rows tr", 1
  end

  test "a settled request's page shows what was asked, the verdict, the outcome, and what deciding it cost" do
    request = settled_request(at: 1.hour.ago)
    older = settled_request(at: 2.hours.ago, status: "denied", reason: "again")
    policy!(@muse, "hob.usage", "review", guidance: "only its own spend")
    UsageEvent.create!(role: "sentinel-reviewer", operation: "sentinel.review", ref: request.ref, model: "claude-sonnet-5", provider: "anthropic",
                       status: "success", cost: 0.0123, units: {}, surface: "muse")
    admin_sign_in

    get "/admin/sentinel/requests/#{request.id}"
    assert_response :ok
    assert_select "h2", /muse asked for hob.usage/
    assert_select "pre", /2026-09-01/
    assert_select "dd", /within its charter/
    assert_select "pre", /"spent": 12/
    assert_select "a[href^='/admin/grants/']", /review/
    assert_select "a[href*='ref=sentinel%2F#{request.id}']", /\$0.0123 over 1 model call/
    assert_select "a[href='/admin/sentinel/requests/#{older.id}']"
    assert_select "form", 1, "no decide form on a settled request (just sign out)"
  end

  test "a held request's page decides it and comes back to it" do
    request = held_request
    admin_sign_in
    get "/admin/sentinel/requests/#{request.id}"
    assert_select "#request-#{request.id} button[value=allow]"

    post "/admin/sentinel/requests/#{request.id}/decide", params: { decision: "deny" },
         headers: { "Referer" => "http://www.example.com/admin/sentinel/requests/#{request.id}" }
    assert_redirected_to "http://www.example.com/admin/sentinel/requests/#{request.id}"
    assert_equal "denied", request.reload.status
  end

  test "a petition's page shows the steward's read, and decides it while pending" do
    petition = pending_petition
    admin_sign_in
    get "/admin/sentinel/petitions/#{petition.id}"
    assert_response :ok
    assert_select "#petition-#{petition.id} button[value=grant]"
    assert_select "dd", /not in its charter/

    petition.update_columns(status: "denied", decided_by: "human")
    get "/admin/sentinel/petitions/#{petition.id}"
    assert_select "h2", /muse petitioned for hob.usage/
    assert_select "button[value=grant]", 0
  end

  test "a request above the person's clearance has no page" do
    request = settled_request(at: 1.hour.ago)
    request.update_columns(realm: "intimate")
    @principal.update!(max_clearance: "personal")
    admin_sign_in
    get "/admin/sentinel/requests/#{request.id}"
    assert_response :not_found
  end
end
