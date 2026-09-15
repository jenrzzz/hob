require_relative "test_helper"

class SentinelClientTest < Minitest::Test
  def setup
    @http = FakeHTTP.new
    @hob = Hob::Client.new(http: @http)
  end

  def test_request_posts_and_reads_the_decision
    @http.respond("id" => "r1", "status" => "completed", "decision" => "allow", "decided_by" => "policy", "result" => { "calls" => 3 })
    request = @hob.sentinel.request(capability: "hob.usage", arguments: { since: "2026-09-01" }, reason: "spend", mission: "m1")
    assert_equal "/v1/sentinel/requests", @http.requests.last.path
    assert_equal({ capability: "hob.usage", arguments: { since: "2026-09-01" }, reason: "spend", mission: "m1" }, @http.requests.last.body)
    assert request.completed?
    assert request.settled?
    assert_equal({ "calls" => 3 }, request.result)

    @http.respond("id" => "r2", "status" => "denied", "rationale" => "no policy permits")
    denied = @hob.sentinel.request(capability: "hob.complete")
    assert denied.denied?
    refute @http.requests.last.body.key?(:reason)
  end

  def test_wait_polls_until_settled
    @http.respond("id" => "r3", "status" => "pending").respond("id" => "r3", "status" => "pending").respond("id" => "r3", "status" => "completed", "result" => 1)
    pending = @hob.sentinel.request(capability: "x")
    assert pending.pending?
    settled = @hob.sentinel.wait(pending)
    assert settled.completed?
    assert_equal [ "/v1/sentinel/requests/r3" ] * 2, @http.requests.last(2).map(&:path)
    assert_equal({ wait: 25 }, @http.requests.last.query)
  end

  def test_decide_capabilities_and_policies
    @http.respond("id" => "r4", "status" => "completed", "decided_by" => "human", "decider" => "jenner")
    assert_equal "jenner", @hob.sentinel.decide("r4", decision: "allow", rationale: "fine").decider
    assert_equal({ decision: "allow", rationale: "fine" }, @http.requests.last.body)

    @http.respond([ { "name" => "hob.usage", "effect" => "allow" } ])
    assert_equal "allow", @hob.sentinel.capabilities.first.effect
    @http.respond("name" => "hob.usage", "effect" => "review")
    assert_equal "review", @hob.sentinel.capability("hob.usage").effect
    assert_equal "/v1/sentinel/capabilities/hob.usage", @http.requests.last.path

    @http.respond("id" => 1, "agent" => "muse", "capability" => "hob.complete", "effect" => "review")
    rule = @hob.sentinel.set_policy(agent: "muse", capability: "hob.complete", effect: "review", constraints: { role: [ "cheap-classifier" ] }, guidance: "strict")
    assert_equal "review", rule.effect
    assert_equal({ agent: "muse", capability: "hob.complete", effect: "review", constraints: { role: [ "cheap-classifier" ] }, guidance: "strict" }, @http.requests.last.body)

    @http.respond("id" => 2, "agent" => nil, "capability" => "*", "effect" => "deny")
    @hob.sentinel.set_policy(capability: "*", effect: "deny")
    assert_nil @http.requests.last.body[:agent]
    assert @http.requests.last.body.key?(:agent), "the default rule sends agent: nil"

    @http.raise_with(Hob::Invalid.new("Capability has already been taken"))
        .respond([ { "id" => 7, "agent" => "muse", "capability" => "hob.complete", "effect" => "review" } ])
        .respond("id" => 7, "agent" => "muse", "capability" => "hob.complete", "effect" => "allow")
    updated = @hob.sentinel.set_policy(agent: "muse", capability: "hob.complete", effect: "allow")
    assert_equal "allow", updated.effect
    assert_equal :patch, @http.requests.last.method
    assert_equal "/v1/sentinel/policies/7", @http.requests.last.path

    @http.respond({})
    assert @hob.sentinel.delete_policy(7)
    assert_equal :delete, @http.requests.last.method

    @http.respond("name" => "mise.plan", "venue" => "webhook", "config" => { "url" => "https://mise.test/hob" })
    cap = @hob.sentinel.register_capability(name: "mise.plan", description: "Plan", venue: "webhook", config: { url: "https://mise.test/hob", secret: "s" })
    assert_equal "webhook", cap.venue
    assert_equal "household", @http.requests.last.body[:realm]
  end
end

class MissionsClientTest < Minitest::Test
  def setup
    @http = FakeHTTP.new
    @hob = Hob::Client.new(http: @http)
  end

  def test_lease_heartbeat_complete
    @http.respond("status" => "empty")
    assert_nil @hob.missions.lease(wait: 25)
    assert_equal({ wait: 25 }, @http.requests.last.body)
    assert_equal "/v1/missions/lease", @http.requests.last.path

    @http.respond("id" => "m1", "status" => "leased", "title" => "Plan", "payload" => { "week" => 38 }, "lease_token" => "tok")
    mission = @hob.missions.lease
    assert mission.leased?
    assert_equal({ "week" => 38 }, mission.payload)

    @http.respond("id" => "m1", "status" => "leased", "lease_token" => "tok")
    @hob.missions.heartbeat(mission, lease: 600)
    assert_equal({ lease_token: "tok", lease: 600 }, @http.requests.last.body)

    @http.respond("id" => "m1", "status" => "completed", "result" => { "ok" => true })
    done = @hob.missions.complete(mission, { ok: true })
    assert done.settled?
    assert_equal({ lease_token: "tok", result: { ok: true } }, @http.requests.last.body)

    @http.respond("id" => "m1", "status" => "failed")
    @hob.missions.fail(mission, "boom")
    assert_equal({ lease_token: "tok", error: "boom" }, @http.requests.last.body)
  end

  def test_create_show_cancel
    @http.respond("id" => "m2", "status" => "queued")
    @hob.missions.create(assignee: "muse", title: "Water the plants", brief: "porch", payload: { pots: 3 }, priority: 1, realm: "household")
    assert_equal({ assignee: "muse", title: "Water the plants", brief: "porch", payload: { pots: 3 }, priority: 1, realm: "household" }, @http.requests.last.body)

    @http.respond("id" => "m2", "status" => "completed")
    assert @hob.missions.show("m2", wait: 30).settled?
    assert_equal({ wait: 30 }, @http.requests.last.query)

    @http.respond("id" => "m2", "status" => "cancelled")
    assert_equal "cancelled", @hob.missions.cancel("m2").status
  end

  def test_work_loop_completes_and_fails
    @http.respond("id" => "m3", "status" => "leased", "payload" => { "n" => 2 }, "lease_token" => "t")
        .respond("id" => "m3", "status" => "completed")
    handled = @hob.missions.work(once: true) { |m| { doubled: m.payload["n"] * 2 } }
    assert_equal 1, handled
    assert_equal({ lease_token: "t", result: { doubled: 4 } }, @http.requests.last.body)

    @http.respond("id" => "m4", "status" => "leased", "lease_token" => "t")
        .respond("id" => "m4", "status" => "failed")
    @hob.missions.work(once: true) { |_m| raise "kitchen fire" }
    assert_equal({ lease_token: "t", error: "RuntimeError: kitchen fire" }, @http.requests.last.body)

    @http.respond("status" => "empty").respond("id" => "m5", "status" => "leased", "lease_token" => "t").respond("id" => "m5", "status" => "completed")
    handled = @hob.missions.work { |_m| throw :stop, nil }
    assert_equal 0, handled
  end
end

class WebhookTest < Minitest::Test
  def test_verify_round_trip
    body = '{"request":"r1","capability":"mise.plan"}'
    signature = Hob::Webhook.sign(secret: "s3cret", body: body)
    assert Hob::Webhook.verify(secret: "s3cret", signature: signature, body: body)
    refute Hob::Webhook.verify(secret: "other", signature: signature, body: body)
    refute Hob::Webhook.verify(secret: "s3cret", signature: signature, body: body + "x")
    refute Hob::Webhook.verify(secret: "s3cret", signature: signature, body: body, now: Time.now.to_i + 600)
    refute Hob::Webhook.verify(secret: "s3cret", signature: "garbage", body: body)
    refute Hob::Webhook.verify(secret: "s3cret", signature: nil, body: body)
  end
end

class FakeSentinelTest < Minitest::Test
  def setup
    @hob = Hob::Fake.new
  end

  def test_scripted_decisions
    @hob.sentinel.allow({ "calls" => 1 }).deny("not for you").hold({ "ok" => true })
    done = @hob.sentinel.request(capability: "hob.usage", reason: "spend")
    assert done.completed?
    assert_equal({ "calls" => 1 }, done.result)
    assert_equal :sentinel, @hob.calls.last.kind
    assert_equal "hob.usage", @hob.calls.last.args[:capability]

    assert @hob.sentinel.request(capability: "hob.complete").denied?

    held = @hob.sentinel.request(capability: "mise.plan")
    assert held.pending?
    assert_equal 1, @hob.sentinel.list(status: "pending").size
    settled = @hob.sentinel.decide(held.id, decision: "allow", rationale: "fine")
    assert settled.completed?
    assert_equal({ "ok" => true }, settled.result)
    assert_equal "human", settled.decided_by
    assert_raises(Hob::Invalid) { @hob.sentinel.decide(held.id, decision: "deny") }
    assert_raises(Hob::Error) { @hob.sentinel.request(capability: "x") }

    @hob.sentinel.offer("hob.usage", effect: "allow").offer("hob.complete", effect: "review")
    assert_equal %w[hob.usage hob.complete], @hob.sentinel.capabilities.map(&:name)
    assert_equal "review", @hob.sentinel.capability("hob.complete").effect
  end

  def test_missions_queue
    assert_nil @hob.missions.lease
    low = @hob.missions.create(assignee: "muse", title: "low")
    high = @hob.missions.create(assignee: "muse", title: "high", priority: 5, payload: { n: 1 })
    leased = @hob.missions.lease
    assert_equal high.id, leased.id
    assert leased.leased?
    assert_equal({ "n" => 1 }, leased.payload)
    assert_raises(Hob::Invalid) { @hob.missions.complete(Hob::Mission.new("id" => low.id, "lease_token" => "x"), {}) }
    assert_equal "completed", @hob.missions.complete(leased, { done: true }).status
    assert_equal({ "done" => true }, @hob.missions.show(leased.id).result)

    handled = @hob.missions.work(once: true) { |m| m.title.upcase }
    assert_equal 1, handled
    assert_equal "LOW", @hob.missions.show(low.id).result
    assert_equal 2, @hob.missions.list(status: "completed").size
    assert_equal "cancelled", @hob.missions.cancel(@hob.missions.create(assignee: "muse", title: "x").id).status
  end
end
