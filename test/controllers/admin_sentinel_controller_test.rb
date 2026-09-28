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
    assert_select "table td", /muse petitioned for hob.usage/
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
end
