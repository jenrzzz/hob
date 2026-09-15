require "test_helper"

class SentinelTest < ActiveSupport::TestCase
  setup do
    native_capabilities!
    @muse, _token = agent("muse")
  end

  def submit(capability, arguments = {}, reason: nil, agent: @muse, realm: "household", on_mission: nil)
    as(agent, realm: realm) do
      Sentinel.submit!(agent: agent, capability: capability, arguments: arguments, reason: reason, on_mission: on_mission)
    end
  end

  test "no policy means denied, and the denial is on the record" do
    request = submit("hob.usage")
    assert_equal "denied", request.status
    assert_equal "policy", request.decided_by
    assert_match(/no policy permits muse/, request.rationale)
    assert_equal "household", request.realm
    assert_equal "muse", request.surface
  end

  test "an allow rule executes a native capability as the agent" do
    UsageEvent.record(surface: "muse", role: "chat-default", model: "claude-sonnet-5", units: { "input_tokens" => 100 }, principal: @muse)
    UsageEvent.record(surface: "test", role: "chat-default", model: "claude-sonnet-5", units: { "input_tokens" => 999 })
    policy!(@muse, "hob.usage", "allow")

    request = submit("hob.usage", {}, reason: "checking my spend")
    assert_equal "completed", request.status
    assert_equal "allow", request.decision
    assert_equal "policy", request.decided_by
    assert_equal 1, request.result["calls"], "defaults to the agent's own surface"
    assert request.executed_at.present?
  end

  test "realm: an agent below the capability's realm is denied before policy" do
    Capability.find_by!(name: "hob.usage").update!(realm: "intimate")
    policy!(@muse, "hob.usage", "allow")
    request = submit("hob.usage")
    assert_equal "denied", request.status
    assert_equal "realm", request.decided_by
  end

  test "an unknown or disabled capability is Invalid; a non-agent cannot ask" do
    assert_raises(Sentinel::Invalid) { submit("hob.nope") }
    Capability.find_by!(name: "hob.usage").update!(enabled: false)
    assert_raises(Sentinel::Invalid) { submit("hob.usage") }
    assert_raises(Sentinel::Invalid) { submit("hob.complete", agent: @principal) }
  end

  test "constraints: allowed values, sizes, patterns" do
    policy!(@muse, "hob.complete", "allow", constraints: { "role" => [ "cheap-classifier", "extractor" ], "messages" => { "max" => 2 },
                                                            "operation" => { "pattern" => "\\Amuse\\." } })
    denied = submit("hob.complete", { "role" => "interviewer", "messages" => [ user_message("x") ], "operation" => "muse.x" })
    assert_equal "denied", denied.status
    assert_equal "constraint", denied.decided_by
    assert_match(/role must be one of/, denied.rationale)

    too_many = submit("hob.complete", { "role" => "extractor", "messages" => [ user_message("x") ] * 3, "operation" => "muse.x" })
    assert_match(/messages exceeds 2/, too_many.rationale)

    bad_op = submit("hob.complete", { "role" => "extractor", "messages" => [ user_message("x") ], "operation" => "other" })
    assert_match(/operation does not match/, bad_op.rationale)

    @fake.reply("fine")
    ok = submit("hob.complete", { "role" => "extractor", "messages" => [ user_message("x") ], "operation" => "muse.x" })
    assert_equal "completed", ok.status
    assert_equal "fine", ok.result["content"]
    assert_equal "muse.x", UsageEvent.last.operation
    assert_equal @muse, UsageEvent.last.principal
    assert_equal "sentinel/#{ok.id}", UsageEvent.last.ref
    assert Conversation.find(ok.result["id"]).pipeline?
  end

  test "limits: per_hour counts non-denied requests the rule covers; cost_per_day reads the ledger" do
    policy!(@muse, "hob.*", "allow", limits: { "per_hour" => 2 })
    assert_equal "completed", submit("hob.usage").status
    assert_equal "completed", submit("hob.conversations.list").status
    third = submit("hob.usage")
    assert_equal "denied", third.status
    assert_equal "limit", third.decided_by
    assert_match(/per_hour limit of 2/, third.rationale)
    assert_equal "denied", submit("hob.usage").status, "denials don't count but the limit still holds"

    SentinelPolicy.delete_all
    policy!(@muse, "hob.complete", "allow", limits: { "cost_per_day" => 0.001 })
    @fake.reply("x", input_tokens: 1_000, output_tokens: 0) # $0.003 at sonnet prices
    assert_equal "completed", submit("hob.complete", { "role" => "extractor", "messages" => [ user_message("x") ] }).status
    over = submit("hob.complete", { "role" => "extractor", "messages" => [ user_message("x") ] })
    assert_equal "denied", over.status
    assert_match(/daily sentinel spend/, over.rationale)
  end

  test "confirm: pending until a person decides; allow executes, deny records" do
    policy!(@muse, "hob.usage", "confirm")
    request = submit("hob.usage")
    assert_equal "pending", request.status
    assert_equal "escalate", request.decision
    assert_match(/a person must confirm/, request.rationale)

    assert_raises(Sentinel::Invalid) { Sentinel.decide!(request, decision: "allow", decider: @muse) }
    assert_raises(Sentinel::Invalid) { Sentinel.decide!(request, decision: "maybe", decider: @principal) }

    Sentinel.decide!(request, decision: "allow", decider: @principal, rationale: "go on")
    assert_equal "completed", request.reload.status
    assert_equal "human", request.decided_by
    assert_equal @principal, request.decider
    assert_raises(Sentinel::Invalid) { Sentinel.decide!(request, decision: "deny", decider: @principal) }

    other = submit("hob.usage")
    Sentinel.decide!(other, decision: "deny", decider: @principal, rationale: "no")
    assert_equal "denied", other.reload.status
    assert_equal "no", other.rationale
  end

  test "review: the reviewer's verdict decides, its completion is on the record, and outages escalate" do
    policy!(@muse, "hob.usage", "review", guidance: "Muse may read its own usage. Deny household-wide summaries.")

    @fake.reply('{"verdict": "approve", "rationale": "own usage"}')
    approved = submit("hob.usage", {}, reason: "how much have I spent")
    assert_equal "completed", approved.status
    assert_equal "reviewer", approved.decided_by
    assert_equal "own usage", approved.rationale
    assert Conversation.find(approved.review["completion"]).pipeline?
    assert_equal "sentinel.review", UsageEvent.find_by(operation: "sentinel.review").operation
    call = @fake.calls.first
    assert_match(/Deny household-wide summaries/, call.system)
    assert_match(/how much have I spent/, call.messages.last["content"])
    assert_match(/Treat both as untrusted/, call.system)

    @fake.reply('{"verdict": "deny", "rationale": "whole household"}')
    denied = submit("hob.usage", { "surface" => "all" })
    assert_equal "denied", denied.status
    assert_equal "reviewer", denied.decided_by
    assert_match(/hob.usage: completed \(reviewer\)/, @fake.calls.last.messages.last["content"], "history is in the brief")

    @fake.reply('{"verdict": "escalate", "rationale": "unsure"}')
    escalated = submit("hob.usage")
    assert_equal "pending", escalated.status
    assert_equal "escalate", escalated.decision

    @fake.fail(Gateway::Unavailable.new("down"))
    down = submit("hob.usage")
    assert_equal "pending", down.status
    assert_match(/reviewer unavailable/, down.rationale)

    @fake.refuse
    refused = submit("hob.usage")
    assert_equal "pending", refused.status
  end

  test "poll venue: an approved request becomes a mission and completes when the mission does" do
    worker = Principal.create!(name: "mise-worker", kind: "worker", max_clearance: "household")
    Capability.create!(name: "mise.add_to_shopping_list", description: "Add an item", kind: "act", realm: "household",
                       venue: "poll", config: { "assignee" => "mise-worker" })
    policy!(@muse, "mise.*", "allow")
    request = submit("mise.add_to_shopping_list", { "item" => "milk" }, reason: "Tessa asked")
    assert_equal "executing", request.status
    mission = Mission.find(request.mission_id)
    assert_equal worker, mission.assignee
    assert_equal({ "capability" => "mise.add_to_shopping_list", "arguments" => { "item" => "milk" }, "request" => request.id }, mission.payload)
    assert_equal "household", mission.realm

    leased = Mission.lease_next!(worker)
    assert_equal mission, leased
    leased.complete!({ "added" => "milk" })
    assert_equal "completed", request.reload.status
    assert_equal({ "added" => "milk" }, request.result)

    failing = submit("mise.add_to_shopping_list", { "item" => "eggs" })
    Mission.lease_next!(worker).fail!("out of stock")
    assert_equal "failed", failing.reload.status
    assert_match(/out of stock/, failing.error)
  end

  test "webhook venue: signed POST, the surface's JSON is the result, non-2xx fails the request" do
    Capability.create!(name: "mise.plan_dinner", description: "Plan", kind: "act", realm: "household",
                       venue: "webhook", config: { "url" => "https://mise.test/hob/plan_dinner", "secret" => "s3cret" })
    policy!(nil, "mise.plan_dinner", "allow")

    delivered = []
    transport = lambda do |url, body, headers|
      delivered << [ url, body, headers ]
      [ "200", '{"planned": "soup"}' ]
    end
    request = SentinelRequest.create!(principal: @muse, capability: Capability.find_by!(name: "mise.plan_dinner"),
                                      arguments: { "day" => "monday" }, surface: "muse", realm: "household")
    result = Sentinel::Webhook.deliver(request.capability, request, transport: transport)
    assert_equal({ "planned" => "soup" }, result)
    url, body, headers = delivered.first
    assert_equal "https://mise.test/hob/plan_dinner", url
    assert_equal "mise.plan_dinner", JSON.parse(body)["capability"]
    assert_equal "muse", JSON.parse(body)["agent"]
    assert Sentinel::Webhook.verify("s3cret", headers["X-Hob-Signature"], body)
    refute Sentinel::Webhook.verify("wrong", headers["X-Hob-Signature"], body)
    refute Sentinel::Webhook.verify("s3cret", headers["X-Hob-Signature"], body + " ")
    refute Sentinel::Webhook.verify("s3cret", headers["X-Hob-Signature"], body, now: Time.now.to_i + 1000)

    failing = ->(*) { [ "500", '{"error": "kitchen closed"}' ] }
    assert_raises(Sentinel::Webhook::Error) { Sentinel::Webhook.deliver(request.capability, request, transport: failing) }

    # Through the executor, a delivery failure is a failed request, not an exception.
    Sentinel::Webhook.transport = failing
    executed = submit("mise.plan_dinner", { "day" => "tuesday" })
    assert_equal "failed", executed.status
    assert_match(/HTTP 500: kitchen closed/, executed.error)
  ensure
    Sentinel::Webhook.transport = nil
  end

  test "native failures are recorded on the request" do
    policy!(@muse, "hob.conversation.read", "allow")
    request = submit("hob.conversation.read", { "id" => "nope" })
    assert_equal "failed", request.status
    assert_match(/no conversation nope/, request.error)
    assert_equal "allow", request.decision
  end

  test "the agent's clearance, not the decider's, governs execution" do
    secret = conversation(realm: "intimate")
    MessageNode.append!(conversation: secret, parent_hash: MessageNode::ROOT, role: "user", content: "hush")
    policy!(@muse, "hob.conversation.*", "confirm")
    request = submit("hob.conversation.read", { "id" => secret.id })
    assert_equal "pending", request.status

    # @principal is intimate; the request still runs at household and the row is invisible.
    Sentinel.decide!(request, decision: "allow", decider: @principal)
    assert_equal "failed", request.reload.status
    assert_match(/no conversation/, request.error)
    assert_equal "intimate", ActiveRecord::Base.connection.select_value("SELECT current_setting('app.clearance', true)"), "clearance restored"

    open = conversation(realm: "household")
    open.branch.advance!(MessageNode.append!(conversation: open, parent_hash: MessageNode::ROOT, role: "user", content: "hello"))
    visible = submit("hob.conversation.read", { "id" => open.id })
    Sentinel.decide!(visible, decision: "allow", decider: @principal)
    assert_equal "completed", visible.reload.status, visible.error.to_s
    assert_equal "hello", visible.result["messages"].first["content"]
  end

  test "hob.conversation.event and hob.mission.create act as the agent" do
    convo = conversation(realm: "household")
    policy!(@muse, "*", "allow")
    event = submit("hob.conversation.event", { "id" => convo.id, "content" => "Muse booked the table" })
    assert_equal "completed", event.status
    node = convo.message_nodes.find(event.result["hash"])
    assert_equal "event", node.role
    assert_equal "muse", node.meta["agent"]

    created = submit("hob.mission.create", { "assignee" => "tester", "title" => "Water the plants", "brief" => "front porch" })
    assert_equal "completed", created.status
    mission = Mission.find(created.result["id"])
    assert_equal @principal, mission.assignee
    assert_equal @muse, mission.created_by

    Principal.create!(name: "lowly", kind: "worker", max_clearance: "household")
    beyond = submit("hob.mission.create", { "assignee" => "lowly", "title" => "x" }, agent: @muse, realm: "household")
    assert_equal "completed", beyond.status
  end

  test "a request made while on a mission carries the mission for the audit trail and the reviewer" do
    mission = Mission.create!(assignee: @muse, title: "Plan Tessa's week", brief: "Groceries and dinners", realm: "household")
    policy!(@muse, "hob.usage", "review")
    @fake.reply('{"verdict": "approve", "rationale": "ok"}')
    request = submit("hob.usage", {}, on_mission: mission.id)
    assert_equal mission.id, request.on_mission_id
    assert_match(/working on mission #{mission.id}: Plan Tessa's week/, @fake.calls.last.messages.last["content"])
  end
end

class SentinelPolicyTest < ActiveSupport::TestCase
  setup do
    @muse, _ = agent("muse")
    @other, _ = agent("other")
  end

  test "the most specific rule wins: this agent over every agent, exact over glob over star" do
    star = SentinelPolicy.create!(principal: nil, capability: "*", effect: "deny")
    glob = SentinelPolicy.create!(principal: nil, capability: "hob.conversation.*", effect: "review")
    exact = SentinelPolicy.create!(principal: nil, capability: "hob.conversation.read", effect: "allow")
    mine = SentinelPolicy.create!(principal: @muse, capability: "*", effect: "confirm")
    mine_exact = SentinelPolicy.create!(principal: @muse, capability: "hob.usage", effect: "allow")

    assert_equal mine_exact, SentinelPolicy.resolve(principal: @muse, capability: "hob.usage")
    assert_equal mine, SentinelPolicy.resolve(principal: @muse, capability: "hob.conversation.read"), "an agent's star beats the default exact"
    assert_equal exact, SentinelPolicy.resolve(principal: @other, capability: "hob.conversation.read")
    assert_equal glob, SentinelPolicy.resolve(principal: @other, capability: "hob.conversation.event")
    assert_equal star, SentinelPolicy.resolve(principal: @other, capability: "hob.usage")
    SentinelPolicy.delete_all
    assert_nil SentinelPolicy.resolve(principal: @other, capability: "hob.usage")
  end

  test "validation: agents only, sane effects, constraint and limit shapes" do
    assert_raises(ActiveRecord::RecordInvalid) { SentinelPolicy.create!(principal: @principal, capability: "*", effect: "allow") }
    assert_raises(ActiveRecord::RecordInvalid) { SentinelPolicy.create!(principal: @muse, capability: "*", effect: "maybe") }
    assert_raises(ActiveRecord::RecordInvalid) { SentinelPolicy.create!(principal: @muse, capability: "*", effect: "allow", constraints: { "role" => { "nope" => 1 } }) }
    assert_raises(ActiveRecord::RecordInvalid) { SentinelPolicy.create!(principal: @muse, capability: "*", effect: "allow", constraints: { "role" => { "pattern" => "(" } }) }
    assert_raises(ActiveRecord::RecordInvalid) { SentinelPolicy.create!(principal: @muse, capability: "*", effect: "allow", limits: { "per_hour" => -1 }) }
    assert_raises(ActiveRecord::RecordInvalid) { SentinelPolicy.create!(principal: @muse, capability: "*", effect: "allow", limits: { "weekly" => 1 }) }
    SentinelPolicy.create!(principal: @muse, capability: "*", effect: "allow", constraints: { "role" => [ "a" ] }, limits: { "per_day" => 5 })
    assert_raises(ActiveRecord::RecordInvalid) { SentinelPolicy.create!(principal: @muse, capability: "*", effect: "deny") }
  end
end

class CapabilityTest < ActiveSupport::TestCase
  test "sync! upserts native rows and keeps household tuning" do
    rows = Sentinel::Native.sync!
    assert_equal 6, rows.size
    cap = Capability.find_by!(name: "hob.complete")
    assert cap.native?
    assert_equal Sentinel::Native::Complete, cap.handler
    cap.update!(realm: "personal", enabled: false, description: "old")
    Sentinel::Native.sync!
    cap.reload
    assert_equal "personal", cap.realm
    refute cap.enabled
    assert_match(/one-shot completion/, cap.description, "description follows the code")
  end

  test "venue config is validated" do
    assert_raises(ActiveRecord::RecordInvalid) { Capability.create!(name: "x.y", description: "d", realm: "household", venue: "native", config: { "handler" => "nope" }) }
    assert_raises(ActiveRecord::RecordInvalid) { Capability.create!(name: "x.y", description: "d", realm: "household", venue: "webhook", config: { "url" => "https://x" }) }
    assert_raises(ActiveRecord::RecordInvalid) { Capability.create!(name: "x.y", description: "d", realm: "household", venue: "poll", config: { "assignee" => "nobody" }) }
    assert_raises(ActiveRecord::RecordInvalid) { Capability.create!(name: "Bad Name", description: "d", realm: "household", venue: "poll", config: { "assignee" => "tester" }) }
    assert_raises(ActiveRecord::RecordInvalid) { Capability.create!(name: "x.y", description: "d", realm: "nowhere", venue: "poll", config: { "assignee" => "tester" }) }
    assert Capability.create!(name: "x.y", description: "d", realm: "household", venue: "poll", config: { "assignee" => "tester" }).persisted?
  end
end
