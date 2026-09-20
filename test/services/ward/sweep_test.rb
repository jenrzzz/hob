require "test_helper"

# WARD.md: the ward's clock. A check that goes quiet is a finding; an
# acknowledgement that lapses reopens what it covered.
class WardSweepTest < ActiveSupport::TestCase
  setup do
    @check = WardCheck.create!(slug: "exposure", interval_seconds: 7.days.to_i, grace_seconds: 1.day.to_i)
    @pings = []
    Notify.transport = ->(url, title, body, _h) { @pings << [ url, title, body ]; "200" }
    ENV["HOB_NOTIFY_URL"] = "https://ntfy.test/hob"
  end

  teardown do
    Notify.transport = nil
    ENV.delete("HOB_NOTIFY_URL")
  end

  def ingest(lines, exit_code: 1)
    Ward::Ingest.call(check: @check, lines: lines, exit_code: exit_code, principal: @principal, triage: false)
  end

  test "nothing changed: no run, no ping" do
    assert_nil Ward::Sweep.call
    assert_equal 0, WardRun.count
    assert_empty @pings
  end

  test "a check that never reported is stale after interval + grace; a complete run resolves the marker" do
    travel 7.days
    assert_not @check.stale?
    assert_nil Ward::Sweep.call

    travel 2.days
    assert @check.stale?
    @fake.reply({ severity: "attention", headline: "The exposure audit has stopped running", summary: "s", next_steps: [] }.to_json)
    run = Ward::Sweep.call
    assert run.sweep?
    assert_nil run.exit_code
    assert_not run.complete?
    stale = WardFinding.find_by!(fingerprint: "stale")
    assert_equal [ stale.id ], run.diff_ids("new")
    assert_equal "error", stale.level
    assert_equal "exposure", stale.subject
    assert_match(/no complete exposure run for 9 days/, stale.message)
    assert_equal "attention", run.triage["severity"]
    assert_equal [ "ward: The exposure audit has stopped running" ], @pings.map { |p| p[1] }

    assert_nil Ward::Sweep.call, "still stale, already reported: quiet"
    assert_equal 1, WardRun.count

    heard = ingest("OK all quiet\n", exit_code: 0)
    assert_equal [ stale.id ], heard.diff_ids("resolved")
    assert stale.reload.resolved?
    assert_not @check.reload.stale?

    travel 9.days
    @fake.reply({ severity: "info", headline: "quiet again", summary: "s", next_steps: [] }.to_json)
    again = Ward::Sweep.call
    assert_equal [ stale.id ], again.diff_ids("reopened")
    assert_not stale.reload.resolved?
  end

  test "an incomplete run does not keep a check from going stale" do
    ingest("ERROR ports: deliberately omitted; partial audit\n", exit_code: 2)
    travel 9.days
    assert @check.reload.stale?
  end

  test "a lapsed acknowledgement reopens the finding and is reported" do
    ingest("FAIL cadance 1.2.3.4:8888: unexpected public TCP port\n")
    finding = WardFinding.first
    finding.acknowledge!(by: @principal, note: "known", until_at: 2.days.from_now)
    assert_nil Ward::Sweep.call

    travel 3.days
    @fake.reply({ severity: "attention", headline: "An acknowledgement lapsed", summary: "s", next_steps: [ "re-ack" ] }.to_json)
    run = Ward::Sweep.call
    assert_equal [ finding.id ], run.diff_ids("expired_acks")
    assert_equal "open", finding.reload.state
    assert_nil finding.acknowledged_at
    assert_equal "known", finding.ack_note, "the note survives as history"
    assert_equal "exposure: 1 acknowledgement(s) expired", run.mechanical_summary
    assert_equal 1, @pings.size
  end

  test "a sweep inside an ingest lands on that run instead of its own" do
    ingest("FAIL a: b\n")
    WardFinding.first.acknowledge!(by: @principal, until_at: 1.day.from_now)
    travel 2.days
    run = ingest("FAIL a: b\nFAIL c: d\n")
    assert_equal 1, run.diff_ids("new").size
    assert_equal 1, run.diff_ids("expired_acks").size
    assert_equal 2, WardRun.count
  end

  test "a disabled check is never stale" do
    @check.update!(enabled: false)
    travel 30.days
    assert_not @check.stale?
    assert_nil Ward::Sweep.call
  end
end
