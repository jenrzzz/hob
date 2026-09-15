require "test_helper"

# The agent side of the sentinel over HTTP: an agent key, what it can and
# cannot reach, and the request lifecycle.
class SentinelRequestsControllerTest < ActionDispatch::IntegrationTest
  setup do
    native_capabilities!
    @muse, @agent_token = agent("muse")
  end

  def agent_auth(extra = {})
    { "Authorization" => "Bearer #{@agent_token}" }.merge(extra)
  end

  test "an agent key reaches only the sentinel and the mission queue" do
    post "/v1/completions", params: { role: "chat-default", messages: [ user_message("hi") ] }, headers: agent_auth, as: :json
    assert_response :forbidden
    assert_match(/agents act through the sentinel/, body["error"])
    get "/v1/conversations", headers: agent_auth
    assert_response :forbidden
    get "/v1/usage", headers: agent_auth
    assert_response :forbidden
    post "/v1/sentinel/policies", params: { capability: "*", effect: "allow" }, headers: agent_auth, as: :json
    assert_response :forbidden
    post "/v1/missions", params: { assignee: "muse", title: "x" }, headers: agent_auth, as: :json
    assert_response :forbidden
    get "/v1/sentinel/capabilities", headers: agent_auth
    assert_response :ok
    assert_empty @fake.calls
  end

  test "capabilities: an agent sees what policy lets it ask for, with the effect to expect" do
    policy!(@muse, "hob.usage", "allow")
    policy!(@muse, "hob.conversation.*", "review")
    policy!(nil, "hob.complete", "deny")
    Capability.find_by!(name: "hob.mission.create").update!(realm: "intimate")

    get "/v1/sentinel/capabilities", headers: agent_auth
    assert_response :ok
    listed = body.to_h { |c| [ c["name"], c["effect"] ] }
    assert_equal({ "hob.conversation.event" => "review", "hob.conversation.read" => "review", "hob.usage" => "allow" }, listed)
    assert body.first["input_schema"].present?

    get "/v1/sentinel/capabilities/hob.complete", headers: agent_auth
    assert_response :not_found
    get "/v1/sentinel/capabilities/hob.usage", headers: agent_auth
    assert_equal "allow", body["effect"]

    get "/v1/sentinel/capabilities", headers: auth
    assert_equal 6, body.size
    assert_equal "any", body.first["effect"]
  end

  test "the request lifecycle: allowed, denied, confirmed by a person, long-polled" do
    policy!(@muse, "hob.usage", "allow")
    policy!(@muse, "hob.conversations.list", "confirm")

    post "/v1/sentinel/requests", params: { capability: "hob.usage", arguments: { since: 1.day.ago.iso8601 }, reason: "spend" },
         headers: agent_auth, as: :json
    assert_response :created
    assert_equal "completed", body["status"]
    assert_equal "muse", body["agent"]
    assert_equal 0, body.dig("result", "calls")
    assert_equal "policy", body["decided_by"]

    post "/v1/sentinel/requests", params: { capability: "hob.complete", arguments: { role: "extractor", messages: [ user_message("x") ] } },
         headers: agent_auth, as: :json
    assert_response :created
    assert_equal "denied", body["status"]
    assert_nil body["result"]
    assert_empty @fake.calls

    post "/v1/sentinel/requests", params: { capability: "hob.conversations.list" }, headers: agent_auth, as: :json
    assert_equal "pending", body["status"]
    id = body["id"]

    get "/v1/sentinel/requests/#{id}", params: { wait: 0 }, headers: agent_auth
    assert_equal "pending", body["status"]

    post "/v1/sentinel/requests/#{id}/decide", params: { decision: "allow" }, headers: agent_auth, as: :json
    assert_response :forbidden

    get "/v1/sentinel/requests", params: { status: "pending" }, headers: auth
    assert_equal [ id ], body.map { |r| r["id"] }

    post "/v1/sentinel/requests/#{id}/decide", params: { decision: "allow", rationale: "harmless" }, headers: auth, as: :json
    assert_response :ok
    assert_equal "completed", body["status"]
    assert_equal "tester", body["decider"]
    assert_equal [], body.dig("result", "conversations")

    post "/v1/sentinel/requests/#{id}/decide", params: { decision: "deny" }, headers: auth, as: :json
    assert_response :unprocessable_entity

    get "/v1/sentinel/requests", headers: agent_auth
    assert_equal 3, body.size
    assert_equal %w[completed denied completed], body.map { |r| r["status"] }.reverse

    post "/v1/sentinel/requests", params: { capability: "hob.nope" }, headers: agent_auth, as: :json
    assert_response :unprocessable_entity
  end

  test "an agent cannot see another agent's requests" do
    other, other_token = agent("other")
    policy!(other, "hob.usage", "allow")
    post "/v1/sentinel/requests", params: { capability: "hob.usage" }, headers: { "Authorization" => "Bearer #{other_token}" }, as: :json
    id = body["id"]
    get "/v1/sentinel/requests/#{id}", headers: agent_auth
    assert_response :not_found
    get "/v1/sentinel/requests", headers: agent_auth
    assert_empty body
    get "/v1/sentinel/requests", params: { agent: "other" }, headers: auth
    assert_equal [ id ], body.map { |r| r["id"] }
  end
end

class SentinelPoliciesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @muse, _ = agent("muse")
  end

  test "people manage rules" do
    post "/v1/sentinel/policies", params: { agent: "muse", capability: "hob.complete", effect: "review",
                                            constraints: { role: [ "cheap-classifier" ] }, limits: { per_day: 50 }, guidance: "Be strict." },
         headers: auth, as: :json
    assert_response :created
    assert_equal "muse", body["agent"]
    assert_equal({ "role" => [ "cheap-classifier" ] }, body["constraints"])
    id = body["id"]

    post "/v1/sentinel/policies", params: { capability: "*", effect: "deny" }, headers: auth, as: :json
    assert_response :created
    assert_nil body["agent"]

    post "/v1/sentinel/policies", params: { agent: "tester", capability: "*", effect: "allow" }, headers: auth, as: :json
    assert_response :unprocessable_entity

    patch "/v1/sentinel/policies/#{id}", params: { effect: "allow", limits: {} }, headers: auth, as: :json
    assert_response :ok
    assert_equal "allow", body["effect"]
    assert_equal({}, body["limits"])

    get "/v1/sentinel/policies", params: { agent: "muse" }, headers: auth
    assert_equal [ "hob.complete" ], body.map { |r| r["capability"] }
    get "/v1/sentinel/policies", headers: auth
    assert_equal 2, body.size

    delete "/v1/sentinel/policies/#{id}", headers: auth
    assert_response :no_content
  end

  test "people register webhook and poll capabilities; secrets never come back" do
    post "/v1/sentinel/capabilities", params: { name: "mise.add_to_shopping_list", description: "Add an item", kind: "act",
                                                realm: "household", venue: "webhook",
                                                config: { url: "https://mise.test/hob", secret: "s3cret" },
                                                input_schema: { type: "object", properties: { item: { type: "string" } } } },
         headers: auth, as: :json
    assert_response :created
    assert_equal({ "url" => "https://mise.test/hob" }, body["config"])
    assert_equal "s3cret", Capability.find_by!(name: "mise.add_to_shopping_list").config["secret"]

    patch "/v1/sentinel/capabilities/mise.add_to_shopping_list", params: { venue: "poll", config: { assignee: "tester" } }, headers: auth, as: :json
    assert_response :ok
    assert_equal "poll", body["venue"]

    post "/v1/sentinel/capabilities", params: { name: "bad", description: "x", realm: "household", venue: "webhook", config: {} }, headers: auth, as: :json
    assert_response :unprocessable_entity

    delete "/v1/sentinel/capabilities/mise.add_to_shopping_list", headers: auth
    assert_response :no_content
    native_capabilities!
    delete "/v1/sentinel/capabilities/hob.usage", headers: auth
    assert_response :unprocessable_entity
  end
end

class MissionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @muse, @agent_token = agent("muse")
  end

  def agent_auth
    { "Authorization" => "Bearer #{@agent_token}" }
  end

  test "a person queues a mission; the agent leases, heartbeats, and completes it" do
    post "/v1/missions/lease", params: { wait: 0 }, headers: agent_auth, as: :json
    assert_response :ok
    assert_equal "empty", body["status"]

    post "/v1/missions", params: { assignee: "muse", title: "Plan the week", brief: "Groceries and dinners", payload: { week: 38 }, priority: 2, realm: "household" },
         headers: auth, as: :json
    assert_response :created
    assert_equal "queued", body["status"]
    assert_equal "tester", body["created_by"]
    id = body["id"]

    post "/v1/missions/lease", params: { lease: 120 }, headers: agent_auth, as: :json
    assert_response :ok
    assert_equal id, body["id"]
    assert_equal "leased", body["status"]
    assert_equal({ "week" => 38 }, body["payload"])
    token = body["lease_token"]
    assert token.present?

    post "/v1/missions/#{id}/heartbeat", params: { lease_token: "wrong" }, headers: agent_auth, as: :json
    assert_response :unprocessable_entity
    post "/v1/missions/#{id}/heartbeat", params: { lease_token: token, lease: 600 }, headers: agent_auth, as: :json
    assert_response :ok
    assert_in_delta 600, Time.zone.parse(body["lease_expires_at"]) - Time.current, 3

    get "/v1/missions/#{id}", headers: auth
    assert_nil body["lease_token"], "only the holder sees the token"

    post "/v1/missions/#{id}/complete", params: { lease_token: token, result: { plan: [ "soup", "stew" ] } }, headers: agent_auth, as: :json
    assert_response :ok
    assert_equal "completed", body["status"]
    assert_equal({ "plan" => [ "soup", "stew" ] }, body["result"])
    assert_nil body["lease_token"]

    post "/v1/missions/#{id}/complete", params: { lease_token: token, result: {} }, headers: agent_auth, as: :json
    assert_response :unprocessable_entity

    get "/v1/missions", params: { status: "completed" }, headers: agent_auth
    assert_equal [ id ], body.map { |m| m["id"] }
  end

  test "fail and cancel; a mission is invisible below its realm; another principal cannot report on it" do
    post "/v1/missions", params: { assignee: "muse", title: "secret", realm: "intimate" }, headers: auth, as: :json
    assert_response :unprocessable_entity, "muse cannot see intimate missions"

    post "/v1/missions", params: { assignee: "tester", title: "secret", realm: "intimate" }, headers: auth, as: :json
    assert_response :created
    secret = body["id"]
    get "/v1/missions/#{secret}", headers: agent_auth
    assert_response :not_found

    post "/v1/missions", params: { assignee: "muse", title: "job" }, headers: auth("X-Hob-Clearance" => "household"), as: :json
    id = body["id"]
    post "/v1/missions/#{id}/fail", params: { lease_token: "x", error: "nope" }, headers: auth, as: :json
    assert_response :not_found, "not the assignee"

    post "/v1/missions/lease", headers: agent_auth, as: :json
    token = body["lease_token"]
    post "/v1/missions/#{id}/fail", params: { lease_token: token, error: "could not" }, headers: agent_auth, as: :json
    assert_equal "failed", body["status"]
    assert_equal "could not", body["error"]

    post "/v1/missions", params: { assignee: "muse", title: "later", realm: "household" }, headers: auth, as: :json
    assert_response :created
    later = body["id"]
    post "/v1/missions/#{later}/cancel", headers: agent_auth, as: :json
    assert_response :forbidden
    post "/v1/missions/#{later}/cancel", headers: auth, as: :json
    assert_equal "cancelled", body["status"]
    post "/v1/missions/#{later}/cancel", headers: auth, as: :json
    assert_response :unprocessable_entity
  end

  test "long-poll lease returns as soon as a mission is queued" do
    Thread.new do
      sleep 1.2
      ActiveRecord::Base.connection_pool.with_connection do
        Clearance.with("household") { Mission.create!(assignee: @muse, created_by: @principal, title: "late", realm: "household") }
      end
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    post "/v1/missions/lease", params: { wait: 5 }, headers: agent_auth, as: :json
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_equal "late", body["title"]
    assert elapsed < 4, "returned after #{elapsed}s"
  end
end
