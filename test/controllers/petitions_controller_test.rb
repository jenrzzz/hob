require "test_helper"

# Capability requests over HTTP: an agent petitions, polls, and sees its own;
# a person decides.
class PetitionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    native_capabilities!
    @muse, @agent_token = agent("muse")
    Notify.transport = ->(*) { }
  end

  teardown { Notify.transport = nil }

  def agent_auth(extra = {})
    { "Authorization" => "Bearer #{@agent_token}" }.merge(extra)
  end

  def steward_says(action, capability: "", effect: "review", rationale: "because")
    spec = { "description" => "Read the calendar.", "kind" => "read", "realm" => "household", "input_schema_json" => "{}",
             "behaviour" => "Reads events.", "result_json" => "{}", "acceptance" => "1. works", "notes" => "" }
    @fake.reply({ "action" => action, "rationale" => rationale, "capability" => capability, "effect" => effect,
                  "constraints_json" => "{}", "limits_json" => "{}", "guidance" => "", "spec" => spec }.to_json)
  end

  test "an agent petitions and is granted; the grant shows up in its capabilities" do
    charter!(@muse, "review")
    get "/v1/sentinel/capabilities", headers: agent_auth
    assert_empty body

    steward_says("grant", capability: "hob.usage", effect: "allow", rationale: "own spend")
    post "/v1/sentinel/petitions", params: { want: "see my spend", capability: "hob.usage", arguments: { since: "2026-09-01" }, reason: "budget" },
         headers: agent_auth, as: :json
    assert_response :created
    assert_equal "granted", body["status"]
    assert_equal "grant", body["action"]
    assert_equal "hob.usage", body["capability"]
    assert_equal "allow", body["effect"]
    assert_equal "own spend", body["rationale"]
    assert_equal "muse", body["agent"]
    assert_nil body["review"], "the steward's completion id is for people"
    id = body["id"]

    get "/v1/sentinel/capabilities", headers: agent_auth
    assert_equal [ [ "hob.usage", "allow" ] ], body.map { |c| [ c["name"], c["effect"] ] }

    get "/v1/sentinel/petitions/#{id}", headers: agent_auth
    assert_response :ok
    assert_equal "granted", body["status"]
    get "/v1/sentinel/petitions", headers: agent_auth
    assert_equal [ id ], body.map { |p| p["id"] }
    get "/v1/sentinel/petitions?status=denied", headers: agent_auth
    assert_empty body

    get "/v1/sentinel/petitions/#{id}", headers: auth
    assert body["review"].present?
  end

  test "a bad petition is 422; no charter is a denial on the record" do
    post "/v1/sentinel/petitions", params: { capability: "hob.usage" }, headers: agent_auth, as: :json
    assert_response :unprocessable_entity
    assert_match(/want is required/, body["error"])

    post "/v1/sentinel/petitions", params: { want: "see my spend" }, headers: agent_auth, as: :json
    assert_response :created
    assert_equal "denied", body["status"]
    assert_equal "policy", body["decided_by"]
  end

  test "a referred petition is pending, long-polls, and a person decides it" do
    charter!(@muse, "confirm")
    steward_says("grant", capability: "hob.conversations.list", effect: "review", rationale: "plausible")
    post "/v1/sentinel/petitions", params: { want: "list conversations", mission: "M1" }, headers: agent_auth, as: :json
    assert_equal "pending", body["status"]
    assert_equal "M1", body["on_mission"]
    id = body["id"]

    post "/v1/sentinel/petitions/#{id}/decide", params: { decision: "grant" }, headers: agent_auth, as: :json
    assert_response :forbidden

    settler = Thread.new do
      sleep 0.3
      Sentinel.decide_petition!(Petition.find(id), decision: "grant", decider: @principal, effect: "confirm",
                                constraints: { "limit" => { "max" => 20 } }, rationale: "twenty at a time")
    end
    get "/v1/sentinel/petitions/#{id}?wait=5", headers: agent_auth
    settler.join
    assert_equal "granted", body["status"]
    assert_equal "human", body["decided_by"]
    assert_equal "confirm", body["effect"]
    assert_equal "twenty at a time", body["rationale"]
    rule = SentinelPolicy.find_by!(principal: @muse, capability: "hob.conversations.list")
    assert_equal({ "limit" => { "max" => 20 } }, rule.constraints)

    steward_says("refer", rationale: "unsure")
    post "/v1/sentinel/petitions", params: { want: "something odd" }, headers: agent_auth, as: :json
    other = body["id"]
    post "/v1/sentinel/petitions/#{other}/decide", params: { decision: "deny", rationale: "no" }, headers: auth, as: :json
    assert_response :ok
    assert_equal "denied", body["status"]
    assert_equal "tester", body["decider"]
    post "/v1/sentinel/petitions/#{other}/decide", params: { decision: "deny" }, headers: auth, as: :json
    assert_response :unprocessable_entity
  end

  test "a person approves a build over HTTP and the forge works it through the mission API" do
    _forge, forge_token = forge!
    charter!(@muse, "review")
    steward_says("build", capability: "hob.calendar.read", effect: "allow", rationale: "nothing reads the calendar")
    post "/v1/sentinel/petitions", params: { want: "read the household calendar" }, headers: agent_auth, as: :json
    assert_equal "pending", body["status"]
    assert_equal "hob.calendar.read", body["capability"]
    assert_equal "Read the calendar.", body["spec"]["description"]
    id = body["id"]

    post "/v1/sentinel/petitions/#{id}/decide", params: { decision: "build" }, headers: auth, as: :json
    assert_response :ok
    assert_equal "building", body["status"]
    mission_id = body["mission"]

    forge_auth = { "Authorization" => "Bearer #{forge_token}" }
    post "/v1/missions/lease", params: { wait: 0 }, headers: forge_auth, as: :json
    assert_equal mission_id, body["id"]
    assert_equal "forge.capability", body["payload"]["kind"]
    assert_equal id, body["payload"]["petition"]
    token = body["lease_token"]
    post "/v1/missions/#{mission_id}/complete", params: { lease_token: token, result: { pull_request: "https://github.com/x/hob/pull/7" } },
         headers: forge_auth, as: :json
    assert_response :ok

    get "/v1/sentinel/petitions/#{id}", headers: agent_auth
    assert_equal "proposed", body["status"]
    assert_equal "https://github.com/x/hob/pull/7", body["pull_request"]

    # Merged and deployed: the capability appears and the petition settles.
    post "/v1/sentinel/capabilities", params: { name: "hob.calendar.read", description: "Calendar", kind: "read", realm: "household",
                                                venue: "webhook", config: { url: "https://cal.test/hook", secret: "s" } }, headers: auth, as: :json
    assert_response :created
    get "/v1/sentinel/petitions/#{id}?wait=1", headers: agent_auth
    assert_equal "granted", body["status"]
    get "/v1/sentinel/capabilities/hob.calendar.read", headers: agent_auth
    assert_equal "allow", body["effect"]
  end
end
