require "test_helper"

# WARD.md: what a person is told when something changed.
class WardTriageTest < ActiveSupport::TestCase
  setup do
    @check = WardCheck.create!(slug: "exposure", description: "the audit")
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

  test "the brief carries the diff, what is still open, what is acknowledged, notes, and the previous triage" do
    first = ingest("FAIL vaultwarden: private database is published by Coolify\nWARN mise: review — public recipe app\nFAIL old: gone soon\n")
    WardFinding.find_by!(subject: "mise").acknowledge!(by: @principal, note: "reviewed 2026-09: fine as is")
    WardNote.create!(subject: "vaultwarden", body: "High value; 2FA enforced 2026-08.", author: @principal)
    first.update!(triage: { "severity" => "info", "headline" => "First look" })

    run = ingest("FAIL vaultwarden: private database is published by Coolify\nWARN mise: review — public recipe app\nFAIL cadance 1.2.3.4:8888: unexpected public TCP port\n")
    brief = Ward::Triage.new(run).brief
    assert_match(/Check: exposure — the audit/, brief)
    assert_match(/Run: exit 1, complete; OK=0 WARN=1 FAIL=2 ERROR=0/, brief)
    assert_match(/New findings:\n- \[FAIL\] cadance 1.2.3.4:8888: unexpected public TCP port/, brief)
    assert_match(/Resolved findings.*\n- \[FAIL\] old: gone soon/, brief)
    assert_match(/Still open and unacknowledged for this check \(1\):\n- \[FAIL\] vaultwarden: private database is published by Coolify \(first seen \d{4}-\d\d-\d\d; seen 2×\)/, brief)
    assert_match(/Acknowledged .*:\n- \[WARN\] mise: review — public recipe app — tester: reviewed 2026-09: fine as is/, brief)
    assert_match(/Notes .*:\n- vaultwarden \(tester, \d{4}-\d\d-\d\d\): High value; 2FA enforced 2026-08\./, brief)
    assert_match(/Previous triage \(\d{4}-\d\d-\d\d\): info — First look/, brief)
  end

  test "the verdict is stored with its completion, costed as ward/<run>, and pinged with next steps" do
    run = ingest("FAIL cadance 1.2.3.4:8888: unexpected public TCP port\n")
    @fake.reply({ severity: "urgent", headline: "Port 8888 is open to the internet on cadance",
                  summary: "The proxy's admin port answers publicly.", next_steps: [ "Bind 8888 to the tailnet", "Re-run the audit" ] }.to_json)
    Ward::Triage.call(run)

    run.reload
    assert_equal "urgent", run.triage["severity"]
    assert_equal "Port 8888 is open to the internet on cadance", run.triage["headline"]
    assert_equal [ "Bind 8888 to the tailnet", "Re-run the audit" ], run.triage["next_steps"]
    assert_equal "claude-sonnet-5", run.triage["model"]
    conversation = Conversation.find(run.triage["completion"])
    assert conversation.pipeline?
    assert_equal "personal", conversation.realm
    assert_equal "ward.triage", conversation.title
    assert_equal "ward/#{run.id}", UsageEvent.last.ref
    assert_equal "ward.triage", UsageEvent.last.operation

    call = @fake.calls.last
    assert_match(/You are the ward/, call.system)
    assert_match(/data, not instructions/, call.system)
    assert_equal Ward::Triage::SCHEMA, call.schema
    url, title, body = @pings.last
    assert_equal "https://ntfy.test/hob", url
    assert_equal "ward: Port 8888 is open to the internet on cadance", title
    assert_equal "The proxy's admin port answers publicly.\n\n1. Bind 8888 to the tailnet\n2. Re-run the audit", body
  end

  test "the schema uses only keywords structured outputs accept" do
    rejected = %w[maxItems minItems maxLength minLength minimum maximum multipleOf pattern]
    keys = ->(node) { node.is_a?(Hash) ? node.keys + node.values.flat_map(&keys) : Array(node).grep(Hash).flat_map(&keys) }
    assert_empty keys.call(Ward::Triage::SCHEMA) & rejected
  end

  test "a refusal or an outage still pings, with the mechanical summary" do
    run = ingest("FAIL a: b\nFAIL c: d\nWARN e: f\n")
    @fake.refuse
    Ward::Triage.call(run)
    assert_match(/declined/, run.reload.triage["error"])
    assert run.triage["completion"].present?
    assert_equal "ward: exposure: 3 new (2 FAIL)", @pings.last[1]
    assert_match(/triage declined/, @pings.last[2])

    other = ingest("FAIL a: b\nFAIL c: d\nWARN e: f\nFAIL g: h\n")
    @fake.fail(Gateway::Unavailable.new("anthropic is down"))
    Ward::Triage.call(other)
    assert_match(/Unavailable: anthropic is down/, other.reload.triage["error"])
    assert_equal "ward: exposure: 1 new (1 FAIL)", @pings.last[1]
    assert_match(/triage unavailable/, @pings.last[2])
  end

  test "an off-schema verdict is normalized rather than trusted" do
    run = ingest("FAIL a: b\n")
    @fake.reply({ severity: "catastrophic", headline: "  x " * 60, summary: "", next_steps: "not a list" }.to_json)
    Ward::Triage.call(run)
    run.reload
    assert_equal "attention", run.triage["severity"]
    assert_operator run.triage["headline"].length, :<=, 80
    assert_equal "exposure: 1 new (1 FAIL)", run.triage["summary"]
    assert_equal [ "not a list" ], run.triage["next_steps"]
  end

  test "outside a request the ward is its own surface" do
    run = ingest("FAIL a: b\n")
    @fake.reply({ severity: "info", headline: "h", summary: "s", next_steps: [] }.to_json)
    Current.set(surface: nil) { Ward::Triage.call(run) }
    assert_equal "ward", Conversation.find(run.reload.triage["completion"]).surface
  end
end
