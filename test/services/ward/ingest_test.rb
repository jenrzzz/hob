require "test_helper"

# WARD.md: a posted audit report becomes findings that persist across runs.
class WardIngestTest < ActiveSupport::TestCase
  REPORT = <<~TXT
    WARN  vaultwarden: review — High value; enforce 2FA and review direct host port exposure.
    FAIL  filebrowser-jfave-app: private route files.jfave.com resolves publicly
    FAIL  cadance 5.78.183.213:8888: unexpected public TCP port
    OK    inventory comparison completed for 40 resources (unknown health is not healthy)
    OK    cadance 5.78.183.213: full TCP scan completed; open=[22, 25, 80, 443, 8888]
    OK=2 WARN=1 FAIL=2 ERROR=0
  TXT

  setup do
    @check = WardCheck.create!(slug: "exposure", description: "the audit")
    Notify.transport = ->(*) { "200" }
  end

  teardown { Notify.transport = nil }

  def ingest(lines = REPORT, exit_code: 1, triage: false, **rest)
    Ward::Ingest.call(check: "exposure", lines: lines, exit_code: exit_code, principal: @principal, triage: triage, **rest)
  end

  test "parses LEVEL lines, ignores the tally, and counts" do
    assert_equal [ [ "warn", "vaultwarden: review — High value; enforce 2FA and review direct host port exposure." ],
                   [ "fail", "filebrowser-jfave-app: private route files.jfave.com resolves publicly" ],
                   [ "fail", "cadance 5.78.183.213:8888: unexpected public TCP port" ],
                   [ "ok", "inventory comparison completed for 40 resources (unknown health is not healthy)" ],
                   [ "ok", "cadance 5.78.183.213: full TCP scan completed; open=[22, 25, 80, 443, 8888]" ] ],
                 Ward::Ingest.parse(REPORT)
    assert_equal [ [ "fail", "x: y" ] ], Ward::Ingest.parse([ "FAIL x: y", "noise without a level", "", "OK=0 WARN=0 FAIL=1 ERROR=0" ])
    assert_equal [ [ "error", "boom" ] ], Ward::Ingest.parse([ [ "ERROR", "boom" ] ]), "already-split pairs are accepted"

    run = ingest
    assert_equal({ "ok" => 2, "warn" => 1, "fail" => 2, "error" => 0 }, run.counts)
    assert_equal 5, run.lines.size
    assert_equal 1, run.exit_code
    assert run.complete?
    assert_equal @principal, run.principal
  end

  test "WARN/FAIL/ERROR lines become findings; OK lines never do; fingerprints are stable" do
    run = ingest
    assert_equal 3, WardFinding.count
    assert_equal 3, run.diff_ids("new").size
    assert_empty run.diff_ids("resolved")

    port = WardFinding.find_by!(level: "fail", subject: "cadance 5.78.183.213:8888")
    assert_equal "cadance 5.78.183.213:8888: unexpected public TCP port", port.message
    assert_equal WardFinding.fingerprint_for("exposure", "fail", port.message), port.fingerprint
    assert_equal 32, port.fingerprint.length
    assert_equal "open", port.state
    assert_equal 1, port.occurrences
    assert_equal run.id, port.first_run_id
    assert_equal "vaultwarden", WardFinding.find_by!(level: "warn").subject

    assert_equal run.id, @check.reload.last_run_id
    assert_in_delta Time.current, @check.last_completed_at, 5

    # The same report again: nothing new, occurrences grow, no change recorded.
    again = ingest
    assert_equal 3, WardFinding.count
    assert_not again.any_changes?
    assert_equal 2, port.reload.occurrences
    assert_equal again.id, port.last_run_id
    assert_equal "exposure: no change", again.mechanical_summary
  end

  test "a complete run resolves what it no longer reports; a later report reopens it" do
    ingest
    port = WardFinding.find_by!(subject: "cadance 5.78.183.213:8888")

    without_port = REPORT.lines.reject { |l| l.include?("8888: unexpected") }.join
    run = ingest(without_port, exit_code: 1)
    assert_equal [ port.id ], run.diff_ids("resolved")
    assert port.reload.resolved?
    assert_equal "resolved", port.state
    assert_equal run.id, port.resolved_run_id
    assert_equal "exposure: 1 resolved", run.mechanical_summary

    back = ingest
    assert_equal [ port.id ], back.diff_ids("reopened")
    assert_empty back.diff_ids("new")
    assert_not port.reload.resolved?
    assert_equal 2, port.occurrences
    assert_equal "exposure: 1 reopened", back.mechanical_summary
  end

  test "an incomplete run (exit 2) records its findings but resolves nothing and does not count as heard from" do
    ingest
    before = @check.reload.last_completed_at
    travel 1.hour
    partial = ingest("ERROR ports: deliberately omitted; partial audit\nFAIL new-thing: undeclared route x.test\n", exit_code: 2)
    assert_not partial.complete?
    assert_equal 2, partial.diff_ids("new").size, "its own findings are still recorded"
    assert_empty partial.diff_ids("resolved"), "nothing absent from a partial audit is resolved"
    assert_equal 3, WardFinding.unresolved.where.not(id: partial.diff_ids("new")).count
    assert_equal before, @check.reload.last_completed_at
    assert_not_equal partial.id, @check.last_run_id
    assert_equal "error", WardFinding.find_by!(subject: "ports").level
    assert_match(/2 new \(1 FAIL\), incomplete \(exit 2\)/, partial.mechanical_summary)

    complete = ingest(REPORT, exit_code: 1)
    assert_equal 2, complete.diff_ids("resolved").size, "the next complete run resolves the partial run's extras"
    assert_equal complete.id, @check.reload.last_run_id
  end

  test "a resolved finding cannot be acknowledged; an open one can, with an expiry; unack reopens" do
    ingest
    port = WardFinding.find_by!(subject: "cadance 5.78.183.213:8888")
    assert_raises(ArgumentError) { port.acknowledge!(by: @principal, until_at: 1.hour.ago) }
    port.acknowledge!(by: @principal, note: "nordlynx proxy; auth required", until_at: 30.days.from_now)
    assert_equal "acknowledged", port.state
    assert_equal @principal, port.acknowledged_by
    assert_includes WardFinding.acknowledged, port
    assert_not_includes WardFinding.open, port
    port.unacknowledge!
    assert_equal "open", port.state

    ingest(REPORT.lines.reject { |l| l.include?("8888") }.join)
    assert_raises(ArgumentError) { port.reload.acknowledge!(by: @principal) }
  end

  test "an unknown check, a bad exit code, or an empty report is Invalid" do
    assert_raises(Ward::Invalid) { Ward::Ingest.call(check: "nope", lines: REPORT, exit_code: 0) }
    assert_raises(Ward::Invalid) { Ward::Ingest.call(check: "exposure", lines: REPORT, exit_code: "two") }
    run = ingest("", exit_code: 0)
    assert run.complete?
    assert_equal({ "ok" => 0, "warn" => 0, "fail" => 0, "error" => 0 }, run.counts)
  end

  test "an ingest with changes is triaged; one without is quiet" do
    @fake.reply({ severity: "attention", headline: "Two public ports and a private route", summary: "s", next_steps: [ "close 8888" ] }.to_json)
    pings = []
    Notify.transport = ->(url, title, body, _h) { pings << [ url, title, body ]; "200" }
    ENV["HOB_NOTIFY_URL"] = "https://ntfy.test/hob"

    run = ingest(triage: true)
    assert_equal "attention", run.triage["severity"]
    assert_equal 1, @fake.calls.size
    assert_equal [ "ward: Two public ports and a private route" ], pings.map { |p| p[1] }

    quiet = ingest(triage: true)
    assert_nil quiet.triage
    assert_equal 1, @fake.calls.size, "no change, no model call"
    assert_equal 1, pings.size
  ensure
    ENV.delete("HOB_NOTIFY_URL")
  end
end
