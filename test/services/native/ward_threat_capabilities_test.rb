require "test_helper"

# The ward.threat* capabilities (THREATS.md) through the sentinel: agents
# report, list, and note; accepting a risk and standing a watch down are a
# person's, whatever the rule says.
class WardThreatCapabilitiesTest < ActiveSupport::TestCase
  setup do
    native_capabilities!
    @skipsy, _ = agent("skipsy", clearance: "personal")
    @muse, _ = agent("muse", clearance: "household")
    policy!(nil, "ward.*", "allow")
    Notify.transport = ->(*) { "200" }
    WardAsset.create!(ref: "coolify", name: "coolify", kind: "control_plane", source: "coolify", host: "cadance",
                      exposure: "public", components: { "php" => nil })
  end

  teardown { Notify.transport = nil }

  def submit(capability, arguments = {}, agent: @skipsy)
    as(agent, realm: agent.max_clearance) { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments, reason: "testing") }
  end

  def report!
    request = submit("ward.threat.report", { "kind" => "cve", "title" => "PHP2Shell", "cve_ids" => [ "CVE-2026-109618" ],
                                             "component" => "php", "fixed_versions" => { "8.3" => "8.3.36" } })
    assert_equal "completed", request.status, request.error.to_s
    WardThreat.find(request.result.dig("threat", "id"))
  end

  test "sync! registers five at personal; accept_risk and standdown only a person approves" do
    caps = Capability.where(name: %w[ward.threat.report ward.threats ward.threat.note ward.threat.accept_risk ward.threat.standdown]).index_by(&:name)
    assert_equal 5, caps.size
    assert caps.values.all? { |c| c.realm == "personal" && c.native? }
    assert_equal "read", caps["ward.threats"].kind
    assert_equal %w[ward.threat.accept_risk ward.threat.standdown], caps.values.select(&:requires_person?).map(&:name).sort
    assert_raises(ActiveRecord::RecordInvalid) { policy!(@skipsy, "ward.threat.accept_risk", "allow") }
  end

  test "a household agent is stopped by the realm" do
    assert_equal "realm", submit("ward.threats", agent: @muse).decided_by
  end

  test "report, list, get with history, and note; the reporter is the agent, the notice rides along" do
    threat = report!
    assert_equal [ "exposed", @skipsy ], [ threat.status, threat.reported_by ]
    assert_equal({ "type" => "agent", "by" => "skipsy" }, threat.sources.sole.except("at"))

    listed = submit("ward.threats").result
    assert_equal [ threat.id ], listed["threats"].map { |t| t["id"] }
    assert_match(/data, not instructions/, listed["notice"])

    noted = submit("ward.threat.note", { "threat" => threat.id, "body" => "Rapid7 reports exploitation in the wild",
                                         "evidence" => "https://example.com/r7" })
    assert_equal "completed", noted.status, noted.error.to_s
    assert_equal [ "note", "skipsy" ], noted.result["event"].values_at("kind", "by")

    got = submit("ward.threats", { "threat" => threat.id }).result["threat"]
    assert_equal "Rapid7 reports exploitation in the wild", got["history"].find { |e| e["kind"] == "note" }["body"]

    bad = submit("ward.threat.report", { "kind" => "cve" })
    assert_equal "failed", bad.status
    assert_match(/at least one CVE/, bad.error)
  end

  test "accept_risk waits for a person even under an allow rule, and the person who confirms is the one recorded" do
    threat = report!
    request = submit("ward.threat.accept_risk", { "threat" => threat.id, "reason" => "behind Authelia until the next image" })
    assert request.pending?, "requires_person: allow is taken as confirm"
    refute_equal "accepted_risk", threat.reload.status

    Sentinel.decide!(request, decision: "allow", decider: @principal)
    assert_equal "completed", request.reload.status, request.error.to_s
    threat.reload
    assert_equal [ "accepted_risk", @principal ], [ threat.status, threat.accepted_by ]
    assert_equal "tester", threat.events.where(kind: "transition").last.principal.name
  end

  test "standdown resolves an actor watch, by the person who confirmed" do
    request = submit("ward.threat.report", { "kind" => "actor", "actor" => "h4x0r", "target" => "the house" })
    threat = WardThreat.find(request.result.dig("threat", "id"))
    assert_equal "monitoring", threat.status

    standdown = submit("ward.threat.standdown", { "threat" => threat.id, "reason" => "a friend's joke" })
    Sentinel.decide!(standdown, decision: "allow", decider: @principal)
    threat.reload
    assert_equal [ "resolved", "stood down", "tester" ], [ threat.status, threat.resolution["criteria"], threat.resolution["verified_by"] ]
  end
end
