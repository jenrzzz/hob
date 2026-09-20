require "test_helper"

# ward.status and ward.audit.run (WARD.md) through the sentinel: an agent
# cleared for `personal` may ask how the house stands and for a check to run.
class WardNativeTest < ActiveSupport::TestCase
  setup do
    native_capabilities!
    WardCheck.create!(slug: "exposure", description: "the audit")
    @ward = Principal.create!(name: "ward", kind: "worker", max_clearance: "personal")
    @butler, _ = agent("butler", clearance: "personal")
    @muse, _ = agent("muse", clearance: "household")
    policy!(nil, "ward.*", "allow")
    Notify.transport = ->(*) { "200" }
  end

  teardown { Notify.transport = nil }

  def submit(capability, arguments = {}, agent: @butler, realm: agent.max_clearance)
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments) }
  end

  test "sync! registers both at personal: one read, one act" do
    status = Capability.find_by!(name: "ward.status")
    assert_equal [ "read", "personal", "native", "ward_status" ], [ status.kind, status.realm, status.venue, status.config["handler"] ]
    run = Capability.find_by!(name: "ward.audit.run")
    assert_equal [ "act", "personal", "native", "ward_audit_run" ], [ run.kind, run.realm, run.venue, run.config["handler"] ]
    assert_equal %w[check], run.input_schema["required"]
  end

  test "a household agent is stopped by the realm before policy" do
    request = submit("ward.status", agent: @muse)
    assert_equal "denied", request.status
    assert_equal "realm", request.decided_by
  end

  test "ward.status returns checks, findings, and the notice" do
    Ward::Ingest.call(check: "exposure", lines: "FAIL cadance 1.2.3.4:8888: unexpected public TCP port\nWARN mise: review — x\n", exit_code: 1, triage: false)
    WardFinding.find_by!(level: "warn").acknowledge!(by: @principal, note: "fine")

    request = submit("ward.status", { "limit" => 1 })
    assert_equal "completed", request.status, request.error.to_s
    result = request.result
    assert_equal [ "exposure" ], result["checks"].map { |c| c["slug"] }
    assert_equal 1, result["checks"].first["open"]
    assert_equal 1, result["checks"].first["acknowledged"]
    assert_equal [ "fail" ], result["open"].map { |f| f["level"] }
    assert_equal [ "fine" ], result["acknowledged"].map { |f| f["ack_note"] }
    assert_match(/data, not instructions/, result["notice"])
  end

  test "ward.audit.run queues one mission for the ward worker and reports a duplicate instead of a second" do
    request = submit("ward.audit.run", { "check" => "exposure", "reason" => "we changed the firewall" })
    assert_equal "completed", request.status, request.error.to_s
    mission = Mission.find(request.result["mission"])
    assert_equal @ward, mission.assignee
    assert_equal @butler, mission.created_by
    assert_equal "ward: run exposure", mission.title
    assert_equal "we changed the firewall", mission.brief
    assert_equal({ "kind" => "ward.audit", "check" => "exposure", "request" => request.id }, mission.payload)
    assert_equal "personal", mission.realm
    assert_equal "queued", request.result["status"]

    again = submit("ward.audit.run", { "check" => "exposure" })
    assert_equal "completed", again.status
    assert_equal mission.id, again.result["mission"]
    assert again.result["queued_before"]
    assert_equal 1, Mission.count

    unknown = submit("ward.audit.run", { "check" => "nope" })
    assert_equal "failed", unknown.status
    assert_match(/no ward check named "nope"/, unknown.error)

    WardCheck.find("exposure").update!(enabled: false)
    Mission.first.cancel!
    disabled = submit("ward.audit.run", { "check" => "exposure" })
    assert_match(/disabled/, disabled.error)

    @ward.update!(name: "retired-ward")
    WardCheck.find("exposure").update!(enabled: true)
    nobody = submit("ward.audit.run", { "check" => "exposure" })
    assert_match(/no ward worker/, nobody.error)
  end
end
