require "test_helper"

# THREATS.md: a threat the ward is told about, matched against the
# inventory, defended at Tier 0/1 on its own, Tier 2 only proposed, and
# resolved only with evidence.
class WardThreatsTest < ActiveSupport::TestCase
  # Coolify's API as the ward's read-only token sees it.
  class FakeCoolify
    attr_accessor :version, :applications, :services, :databases, :servers

    def initialize
      @version = "4.0.0-beta.420"
      @servers = [ { "uuid" => "s1", "name" => "cadance", "ip" => "5.161.10.20",
                     "settings" => { "docker_version" => "29.8.0", "patch_checked_at" => Time.current.utc.iso8601,
                                     "patch_check_result" => { "reboot_required" => false, "security_updates" => 0, "total_updates" => 3, "updates" => [] } } } ]
      @applications = [ { "uuid" => "a1", "name" => "feedcurator", "fqdn" => "https://feeds.example.com", "destination" => { "server" => { "uuid" => "s1" } },
                          "docker_registry_image_name" => "ghcr.io/jenrzzz/feedcurator", "docker_registry_image_tag" => "1.4.2" } ]
      @services = [ { "uuid" => "v1", "name" => "wiki", "server_uuid" => "s1", "applications" => [ { "image" => "php:8.3.30-fpm" } ] } ]
      @databases = [ { "uuid" => "d1", "name" => "hob-postgres", "image" => "postgres:16.4", "server_uuid" => "s1" } ]
    end

    def url
      "https://coolify.example.com"
    end

    def service(_uuid)
      raise "the list rows carry their applications"
    end
  end

  PHP = {
    "kind" => "cve", "title" => "PHP2Shell RCE in PHP core", "cve_ids" => %w[CVE-2026-109618 CVE-2026-109619],
    "component" => "php", "fixed_versions" => { "8.3" => "8.3.36", "8.4" => "8.4.27" },
    "gotchas" => [ "FPM workers restarted after the patch" ], "claimed_severity" => "critical",
    "source" => { "type" => "agent", "ref" => "hetzner mail 4411" }, "exploited" => true
  }.freeze

  setup do
    @worker = Principal.create!(name: "ward", kind: "worker", max_clearance: "personal")
    WardCheck.create!(slug: "exposure", description: "the audit")
    @skipsy, _ = agent("skipsy", clearance: "personal")
    @coolify = FakeCoolify.new
    @pings = []
    ENV["HOB_NOTIFY_URL"] = "https://ntfy.test/house"
    Notify.transport = ->(_url, title, body, _headers) { @pings << [ title, body ]; "200" }
    @todos = todo_backend("jenner-of", realm: "personal", primary: true)
    ENV["HOB_WARD_TODO_BACKEND"] = "jenner-of"
    Web.resolver = ->(_host) { [ "93.184.216.34" ] }
    @tags = %w[v4.0.0-beta.419 v4.0.0-beta.420]
    Web.transport = lambda do |_verb, uri, _address, _body, _headers|
      raise "unexpected request to #{uri}" unless uri.host == "api.github.com"

      [ 200, @tags.map { |t| { "name" => t } }.to_json, { "content-type" => "application/json" } ]
    end
  end

  teardown do
    Notify.transport = nil
    Web.transport = nil
    Web.resolver = nil
    Todos::Backends::Fake.reset!
    %w[HOB_NOTIFY_URL HOB_WARD_TODO_BACKEND].each { |k| ENV.delete(k) }
  end

  def sync!
    Ward::Inventory.sync!(client: @coolify)
  end

  def coolify_asset
    WardAsset.find_by!(ref: "coolify")
  end

  def jenner
    @principal
  end

  test "the inventory: Coolify's resources, images, and versions, its own stack, and what went away" do
    result = sync!
    assert_equal 5, result["assets"], "coolify, a server, an app, a service, a database; no scan targets"

    coolify = coolify_asset
    assert_equal({ "coolify" => "4.0.0-beta.420", "php" => nil, "laravel" => nil }, coolify.components)
    assert_equal [ "public", "cadance" ], [ coolify.exposure, coolify.host ]
    assert_equal [ "4.0.0-beta.420", "coolify" ], coolify.believed("coolify").first(1) + [ coolify.believed("coolify").second.source ]

    wiki = WardAsset.find_by!(name: "wiki")
    assert_equal [ "service", "cadance", "tailnet" ], [ wiki.kind, wiki.host, wiki.exposure ]
    assert_equal({ "php" => "8.3.30" }, wiki.components)
    assert_equal "localhost", WardAsset.find_by!(name: "hob-postgres").exposure
    assert_equal "public", WardAsset.find_by!(name: "feedcurator").exposure
    assert_equal "public", WardAsset.find_by!(ref: "server:s1").exposure

    @coolify.services = []
    sync!
    assert wiki.reload.gone_at, "a resource Coolify no longer reports is gone, not deleted"
    assert_empty WardAsset.present.with_component("php").where(name: "wiki")

    refute Ward::Inventory::Coolify.method_defined?(:set_env), "the ward's client cannot write"
    refute Ward::Inventory::Coolify.method_defined?(:restart)
  end

  test "component names: the product an image runs, spelled the way NVD spells it" do
    {
      "vaultwarden/server" => { "vaultwarden" => nil },
      "pgvector/pgvector:pg16" => { "postgres" => nil, "pgvector" => nil },
      "quay.io/oauth2-proxy/oauth2-proxy:latest" => { "oauth2_proxy" => nil },
      "prom/node-exporter:v1.8.2" => { "node_exporter" => "1.8.2" },
      "docker.io/library/nginx:1.27.3" => { "nginx" => "1.27.3" },
      "ghcr.io/coollabsio/coolify" => { "coolify" => nil, "php" => nil, "laravel" => nil },
      "localhost:5000/server" => { "server" => nil }
    }.each { |image, components| assert_equal components, Ward::Inventory.components_for(image), image }

    proxy = WardAsset.create!(ref: "coolify:p", name: "oauth2-proxy", kind: "service", source: "coolify",
                              components: Ward::Inventory.components_for("quay.io/oauth2-proxy/oauth2-proxy:7.6.0"))
    vault = WardAsset.create!(ref: "coolify:v", name: "vaultwarden-wkcks0", kind: "service", source: "coolify",
                              components: Ward::Inventory.components_for("vaultwarden/server"))
    assert_equal [ proxy ], WardAsset.with_component("OAuth2-Proxy").to_a, "however a reporter spells it"
    assert_equal [ vault ], WardAsset.with_component("vaultwarden").to_a
    assert_equal [ proxy ], WardAsset.with_component("oauth2_proxy").to_a, "and the asset's own name matches too"
    proxy.observe!(component: "oauth2-proxy", version: "7.6.1", source: "probe")
    assert_equal "7.6.1", proxy.believed("oauth2_proxy").first

    threat, _ = Ward::Threats.report!({ "kind" => "cve", "cve_ids" => [ "CVE-2026-10001" ], "component" => "OAuth2-Proxy",
                                        "fixed_versions" => { "*" => "7.7.0" } }, by: @skipsy)
    assert_equal "oauth2_proxy", threat.component
    assert_equal [ [ "oauth2-proxy", "7.6.1", "vulnerable" ] ], threat.affected.map { |a| a.values_at("name", "version", "verdict") }
  end

  test "versions: per branch, floating tags and unknown lines are never fixed" do
    fixed = { "8.3" => "8.3.36", "8.4" => "8.4.27" }
    assert_equal "vulnerable", Ward::Versions.verdict("8.3.30", fixed).first
    assert_equal "fixed", Ward::Versions.verdict("8.3.36", fixed).first
    assert_equal "fixed", Ward::Versions.verdict("8.4.30", fixed).first
    assert_equal "unknown", Ward::Versions.verdict("8.3", fixed).first, "a floating tag says nothing about the patch"
    assert_equal "unknown", Ward::Versions.verdict("8.2.29", fixed).first, "no fix named for 8.2"
    assert_equal "fixed", Ward::Versions.verdict("8.5.0", fixed).first, "a newer line than any fixed"
    assert_equal "unknown", Ward::Versions.verdict(nil, fixed).first
    assert_equal "unknown", Ward::Versions.verdict("8.3.30", {}).first
    assert_equal "vulnerable", Ward::Versions.verdict("4.0.0-beta.420", { "*" => "4.0.0-beta.421" }).first
    kernel = { "6.8" => "6.8.12", "6.18" => "6.18.52", "ubuntu:6.8.0" => "6.8.0-140" }
    assert_equal "vulnerable", Ward::Versions.verdict("6.18.50", kernel).first, "upstream numbering, upstream's fix"
    assert_equal "vulnerable", Ward::Versions.verdict("6.8.0-139", kernel, scheme: "ubuntu").first
    assert_equal "fixed", Ward::Versions.verdict("6.8.0-140", kernel, scheme: "Ubuntu").first
    assert_equal [ "unknown", "no ubuntu fixed version is known; upstream's do not apply" ],
                 Ward::Versions.verdict("6.8.0-139", { "6.8" => "6.8.12" }, scheme: "ubuntu"), "a backporting distro is never held to upstream's numbers"
    assert_equal "unknown", Ward::Versions.verdict("7.0.0-34", kernel, scheme: "ubuntu").first, "no Ubuntu fix named for 7.0"
    assert_equal "unknown", Ward::Versions.verdict("6.8.0", { "ubuntu:6.8.0" => "6.8.0-140" }).first, "nor upstream to Ubuntu's"
    assert_equal "8.3.30", Ward::Versions.from_tag("8.3.30-fpm-alpine")
    assert_equal "4.0.0-beta.420", Ward::Versions.from_tag("v4.0.0-beta.420")
    assert_nil Ward::Versions.from_tag("latest")
  end

  test "worked example 1, PHP2Shell: unverified, awaiting upstream, a confirmed upgrade, two fresh checks, the gotcha, then resolved" do
    sync!
    threat, merged = Ward::Threats.report!(PHP, by: @skipsy)
    refute merged

    assert_equal "exposed", threat.status
    assert_equal "verified", threat.confidence, "the wiki's PHP is a known vulnerable version"
    refute threat.exploited?, "an agent's word on exploitation is a claim"
    assert_equal "high", threat.assessed_severity, "a claimed critical is capped at high without evidence of exploitation"
    coolify_entry = threat.affected.find { |a| a["name"] == "coolify" }
    assert_equal [ "unknown", "public" ], coolify_entry.values_at("verdict", "exposure"), "Coolify is PHP, but no one has probed which"
    wiki_entry = threat.affected.find { |a| a["name"] == "wiki" }
    assert_equal [ "8.3.30", "vulnerable" ], wiki_entry.values_at("version", "verdict")
    assert_equal %w[reported transition triaged transition], threat.events.first(4).map(&:kind)
    assert_equal %w[triaged exposed], threat.events.where(kind: "transition").pluck(:to_status)

    actions = threat.posture.map { |p| p["action"] }
    assert_equal [ "rescan", "raise scan cadence", "get the version", "open task", "notify" ], actions
    mission = Mission.find(threat.posture.first["ref"])
    assert_equal [ @worker, "ward.audit", "exposure" ], [ mission.assignee, mission.payload["kind"], mission.payload["check"] ]
    probe = Mission.find(threat.posture.find { |p| p["action"] == "get the version" }["ref"])
    assert_equal [ @worker, { "kind" => "ward.probe" } ], [ probe.assignee, probe.payload ]
    assert_match(/probe queued for coolify php/, threat.posture.find { |p| p["action"] == "get the version" }["result"])
    assert_equal [ probe, true ], Ward.queue_probe!, "one probe mission at a time"
    schedule = Schedule.find(threat.schedule_id)
    assert_equal [ "0 */6 * * *", "exposure" ], [ schedule.cron, schedule.payload["check"] ]
    assert_match(/\Ajenner-of:/, threat.todo_id)
    assert_equal 1, @pings.size
    assert_match(/exposed: PHP2Shell/, @pings.last.first)

    # Jenner's call: wait for the upstream image.
    Ward::Threats.await_upstream!(threat, upstream: { "source" => "github", "repository" => "coollabsio/coolify", "current" => "4.0.0-beta.420" }, by: jenner)
    assert_equal "awaiting_upstream", threat.reload.status
    assert_equal 1, @pings.size, "no nagging while it waits"

    assert_empty Ward::Resolver.call, "nothing upstream yet: quiet"
    assert threat.reload.upstream["last_polled_at"]
    assert_empty Ward::Resolver.call, "and not polled again before its cadence"

    travel 7.hours
    @tags << "v4.0.0-beta.421"
    assert_equal [ [ threat.id, "landed" ] ], Ward::Resolver.call
    threat.reload
    assert_equal "v4.0.0-beta.421", threat.upstream.dig("landed", "tag")
    upgrade = threat.pending_proposals.sole
    assert_equal [ 2, "upgrade" ], upgrade.values_at("tier", "action")
    assert_match(/proposes: Upgrade to v4.0.0-beta.421/, @pings.last.first)
    assert_equal "awaiting_upstream", threat.status, "the upgrade is a person's call"

    error = assert_raises(Ward::Invalid) { Ward::Threats.decide!(threat, upgrade["id"], decision: "confirm", by: @skipsy) }
    assert_match(/only a person/, error.message)
    Ward::Threats.decide!(threat, upgrade["id"], decision: "confirm", by: jenner)
    assert_equal "mitigating", threat.reload.status

    # The upgrade happens; Coolify says so, a probe sees the PHP inside, the
    # wiki's image moves to a fixed tag.
    @coolify.version = "4.0.0-beta.421"
    @coolify.services.first["applications"].first["image"] = "php:8.3.36-fpm"
    travel 10.minutes
    sync!
    coolify_asset.observe!(component: "php", version: "8.3.36", source: "probe", principal: @worker)
    assert_equal [ [ threat.id, "monitoring" ] ], Ward::Resolver.call
    threat.reload
    assert_equal [ "monitoring", 1 ], [ threat.status, threat.passes.size ]
    assert_equal "none", threat.assessed_severity

    travel 30.minutes
    sync!
    assert_empty Ward::Resolver.call, "a second check needs an hour between"

    travel 40.minutes
    assert_empty Ward::Resolver.call, "and a fresh observation since the first"
    sync!
    coolify_asset.observe!(component: "php", version: "8.3.36", source: "probe", principal: @worker)
    assert_empty Ward::Resolver.call, "two checks, but the gotcha is open"
    threat.reload
    assert_equal [ "monitoring", 2 ], [ threat.status, threat.passes.size ]
    assert threat.events.where(kind: "note").where("body LIKE 'waiting on gotcha 0%'").exists?

    assert_raises(Ward::Invalid) { Ward::Threats.satisfy!(threat, 0, evidence: "trust me", by: @skipsy) }
    Ward::Threats.satisfy!(threat, 0, evidence: "php-fpm restarted 14:02; workers report 8.3.36", by: jenner)

    travel 61.minutes
    sync!
    coolify_asset.observe!(component: "php", version: "8.3.36", source: "probe", principal: @worker)
    assert_equal [ [ threat.id, "resolved" ] ], Ward::Resolver.call
    threat.reload
    assert_equal "resolved", threat.status
    assert_match(/at or past the fixed version, on 3 checks/, threat.resolution["criteria"])
    assert_equal 3, threat.resolution.dig("evidence", "passes").size
    assert_equal "ward", threat.resolution["verified_by"]
    assert_nil threat.schedule_id
    refute Schedule.exists?(schedule.id), "the raised cadence ends with the threat"
    assert_equal "done", Todos.find(threat.todo_id)["status"]
    assert_match(/resolved: PHP2Shell/, @pings.last.first)

    # A rollback: what answers on the wire is below the fix again.
    travel 2.hours
    coolify_asset.observe!(component: "php", version: "8.3.30", source: "probe", principal: @worker)
    assert_equal [ [ threat.id, "reopened" ] ], Ward::Resolver.call
    threat.reload
    assert_equal [ "monitoring", [] ], [ threat.status, threat.passes ]
    assert_nil threat.resolution
    assert_match(/regression: coolify php 8.3.30/, threat.events.where(kind: "transition").last.body)
    assert_equal "open", Todos.find(threat.todo_id)["status"]
    assert_match(/reopened/, @pings.last.first)
  end

  test "a report naming an open CVE merges into it, and a person's word on exploitation is taken" do
    sync!
    first, _ = Ward::Threats.report!(PHP.merge("component" => nil, "fixed_versions" => nil), by: @skipsy)
    assert_equal "not_exposed", first.events.where(kind: "triaged").sole.data["status"]
    assert_equal "resolved", first.reload.status, "no component named: unmatched, said as such"
    assert_match(/unmatched/, first.resolution["criteria"])

    second, _ = Ward::Threats.report!(PHP, by: @skipsy)
    refute_equal first.id, second.id, "a resolved threat is not merged into"

    pings = @pings.size
    again, merged = Ward::Threats.report!({ "kind" => "cve", "cve_ids" => [ "cve-2026-109619" ], "exploited" => true,
                                            "source" => { "type" => "feed", "ref" => "https://www.cisa.gov/kev" } }, by: jenner)
    assert merged
    assert_equal second.id, again.id
    assert again.exploited?
    assert_equal %w[agent feed], again.sources.map { |s| s["type"] }
    assert_equal "critical", again.assessed_severity, "known exploited, on a public asset"
    assert_equal 1, WardThreat.open.count
    assert_equal pings, @pings.size, "a merge that does not change the status says nothing new"
  end

  test "unmatched is resolved, said as such, and reopens when the inventory comes to match it" do
    threat, _ = Ward::Threats.report!(PHP, by: @skipsy)
    assert_equal "resolved", threat.status
    assert_equal "not exposed (unmatched)", threat.resolution["criteria"]
    assert_match(/not exposed: PHP2Shell/, @pings.last.first)

    sync!
    assert_equal [ [ threat.id, "reopened" ] ], Ward::Resolver.call
    assert_equal "monitoring", threat.reload.status
    assert_match(/the inventory now matches/, threat.events.where(kind: "transition").last.body)
  end

  test "a host runs a kernel: a kernel CVE matches every host, unverified until probed, each held to its own numbering" do
    kernel = { "kind" => "cve", "title" => "Linux kernel missing initialization", "cve_ids" => [ "CVE-2026-46300" ],
               "component" => "linux_kernel", "fixed_versions" => { "6.18" => "6.18.52", "ubuntu:6.8.0" => "6.8.0-140" } }
    sync!
    pi = WardAsset.create!(ref: "manual:tomcod", name: "tomcod", kind: "host", host: "tomcod", source: "person",
                           declared: { "components" => [ "linux_kernel" ] }, last_seen_at: Time.current)
    cadance = WardAsset.find_by!(ref: "server:s1")
    assert_equal({ "linux_kernel" => nil, "docker" => "29.8.0", "moby" => "29.8.0" }, cadance.components)

    threat, _ = Ward::Threats.report!(kernel, by: @skipsy)
    assert_equal [ "exposed", "unverified" ], [ threat.status, threat.confidence ], "never unmatched: every host runs one"
    assert_equal %w[cadance tomcod], threat.affected.map { |a| a["name"] }

    cadance.observe!(component: "linux_kernel", version: "6.8.0-139", source: "probe",
                     data: { "scheme" => "ubuntu", "release" => "6.8.0-139-generic" })
    pi.observe!(component: "linux_kernel", version: "6.18.52", source: "probe", data: { "release" => "6.18.52+rpt-rpi-2712" })
    Ward::Threats.triage!(threat)
    assert_equal [ [ "cadance", "6.8.0-139", "ubuntu", "vulnerable" ], [ "tomcod", "6.18.52", nil, "fixed" ] ],
                 threat.reload.affected.map { |a| a.values_at("name", "version", "scheme", "verdict") }
    assert_equal "verified", threat.confidence
  end

  test "a server's Docker Engine is on the inventory at the version Coolify read, by both of NVD's names" do
    sync!
    cadance = WardAsset.find_by!(ref: "server:s1")
    assert_equal({ "linux_kernel" => nil, "docker" => "29.8.0", "moby" => "29.8.0" }, cadance.components)
    assert_equal [ "29.8.0", "coolify" ], [ cadance.believed("moby").first, cadance.believed("moby").second.source ]

    threat, _ = Ward::Threats.report!({ "kind" => "cve", "cve_ids" => [ "CVE-2026-20001" ], "component" => "moby",
                                        "fixed_versions" => { "29.8" => "29.8.1" } }, by: @skipsy)
    assert_equal [ [ "cadance", "29.8.0", "vulnerable" ] ], threat.affected.map { |a| a.values_at("name", "version", "verdict") }
  end

  test "the patches check: Coolify's own patch check per server, as findings, posted when it changes or daily" do
    now = Time.zone.parse("2026-10-30T12:00:00Z")
    update = ->(package, security) { { "package" => package, "security" => security, "current_version" => "1", "new_version" => "2" } }
    servers = [
      { "name" => "tabitha", "settings" => { "patch_checked_at" => "2026-10-25T04:01:05Z",
                                             "patch_check_result" => { "reboot_required" => false, "security_updates" => 0, "total_updates" => 22,
                                                                       "updates" => [ update.("cloud-init", false) ] } } },
      { "name" => "agentbox", "settings" => { "patch_checked_at" => "2026-10-25T04:02:05Z",
                                              "patch_check_result" => { "reboot_required" => true, "security_updates" => 2, "total_updates" => 39,
                                                                        "updates" => [ update.("openssl", true), update.("libssl3t64", true), update.("vim", false) ] }.to_json } },
      { "name" => "cadance", "settings" => { "patch_checked_at" => "2026-10-12T04:00:08Z", "patch_check_result" => { "security_updates" => 0 } } },
      { "name" => "haddock", "settings" => {} }
    ]
    assert_equal [
      "WARN agentbox: 2 security updates pending: libssl3t64, openssl",
      "WARN agentbox: reboot required; what is installed is not all running, a kernel included if one was updated",
      "WARN cadance: Coolify's patch check is more than 8 days old",
      "OK cadance: no security updates pending (0 others)",
      "WARN haddock: Coolify has no patch check for it",
      "OK tabitha: no security updates pending (22 others)"
    ], Ward::Patches.lines_for(servers, now: now)

    run = Ward::Patches.ingest!(servers, now: now)
    assert_equal 4, run.diff["new"].size
    assert_equal [ 86_400, 86_400 ], Ward::Patches.check.values_at(:interval_seconds, :grace_seconds)
    assert_nil Ward::Patches.ingest!(servers, now: now + 1.hour), "nothing changed, and a run is not due"

    servers[1]["settings"]["patch_check_result"] = { "reboot_required" => false, "security_updates" => 0, "updates" => [] }
    run = Ward::Patches.ingest!(servers, now: now + 2.hours)
    assert_equal 2, run.diff["resolved"].size, "patched and rebooted"
    assert Ward::Patches.ingest!(servers, now: now + 2.hours + 1.day), "daily, so the check is not stale while Coolify holds"
  end

  test "worked example 2, an actor: Tier 1 at most on a stranger's word, a window, indicators, and a person's resolve" do
    sync!
    threat, _ = Ward::Threats.report!({ "kind" => "actor", "actor" => "h4x0r", "target" => "feedcurator", "claimed_severity" => "critical",
                                        "source" => { "type" => "person", "ref" => "https://forum.example/t/1" } }, by: jenner)
    assert_equal "monitoring", threat.status
    assert_equal "medium", threat.assessed_severity, "a stranger's words alone never raise an actor past medium"
    assert_in_delta 7.days.from_now, threat.expires_at, 5
    assert_equal [ "feedcurator" ], threat.affected.filter_map { |a| a["name"] if a["asset"] }
    assert_equal [ "rescan", "raise scan cadence", "notify" ], threat.posture.map { |p| p["action"] }
    assert_empty threat.proposals, "no Tier 2 on a claim"

    _, merged = Ward::Threats.report!({ "kind" => "actor", "actor" => "H4X0R", "target" => "feedcurator" }, by: @skipsy)
    assert merged, "the same actor on the same surface, inside the window"

    # An agent's flag resets the clock and is told, but proposes nothing.
    travel 3.days
    Ward::Threats.note!(threat, body: "they posted our IP again", by: @skipsy, indicator: true)
    assert_in_delta 7.days.from_now, threat.reload.expires_at, 5
    assert_empty threat.proposals
    assert_match(/indicator reported/, @pings.last.first)

    # Ward's own run: a new public port on the named surface is an observed indicator.
    Ward::Ingest.call(check: "exposure", lines: "FAIL feedcurator: unexpected public TCP port 8080\n", exit_code: 1, triage: false)
    threat.reload
    assert_equal 2, threat.events.where(kind: "indicator").count
    block = threat.pending_proposals.sole
    assert_equal [ 2, "block" ], block.values_at("tier", "action")

    travel 8.days
    assert_includes Ward::Resolver.call, [ threat.id, "expired" ]
    threat.reload
    assert_equal "expired", threat.status
    resolve = threat.pending_proposals.find { |p| p["action"] == "resolve" }
    assert resolve

    Ward::Threats.decide!(threat, resolve["id"], decision: "decline", by: jenner)
    assert_equal "monitoring", threat.reload.status, "declining a quiet resolve watches another window"

    travel 8.days
    Ward::Resolver.call
    resolve = threat.reload.pending_proposals.find { |p| p["action"] == "resolve" }
    Ward::Threats.decide!(threat, resolve["id"], decision: "confirm", by: jenner)
    threat.reload
    assert_equal "resolved", threat.status
    assert_equal "tester", threat.resolution["verified_by"]
    assert_match(/quiet window/, threat.resolution["criteria"])
    assert_nil threat.schedule_id
  end

  test "accepting a risk and standing down are a person's, with a reason; an accepted risk re-surfaces" do
    sync!
    threat, _ = Ward::Threats.report!(PHP, by: @skipsy)
    assert_raises(WardThreat::BadTransition) { threat.move!("accepted_risk") }
    assert_raises(Ward::Invalid) { Ward::Threats.accept_risk!(threat, reason: "fine", by: @skipsy) }
    assert_raises(Ward::Invalid) { Ward::Threats.accept_risk!(threat, reason: " ", by: jenner) }

    Ward::Threats.accept_risk!(threat, reason: "Coolify's panel is behind Authelia; patch with the next image", by: jenner, review_days: 14)
    threat.reload
    assert_equal [ "accepted_risk", jenner ], [ threat.status, threat.accepted_by ]
    assert_in_delta 14.days.from_now, threat.review_at, 5

    travel 15.days
    pings = @pings.size
    assert_includes Ward::Resolver.call, [ threat.id, "reviewed" ]
    assert_equal pings + 1, @pings.size
    assert_match(/still accepted/, @pings.last.first)
    assert_equal "accepted_risk", threat.reload.status, "never auto-resolves on a clock"

    assert_raises(Ward::Invalid) { Ward::Threats.standdown!(threat, reason: "x", by: jenner) }
  end
end
