require "test_helper"

# THREATS.md: what the ward reads from outside, through Web: NVD at triage
# (opt-in) and the upstream watch. Feeds are evidence; they never set
# ward's severity.
class WardThreatFeedsTest < ActiveSupport::TestCase
  NVD_ANSWER = {
    "vulnerabilities" => [ { "cve" => {
      "id" => "CVE-2026-109618", "cisaExploitAdd" => "2026-10-20", "cisaActionDue" => "2026-11-10",
      "metrics" => { "cvssMetricV31" => [ { "cvssData" => { "baseSeverity" => "CRITICAL" } } ] },
      "configurations" => [ { "nodes" => [ { "cpeMatch" => [
        { "vulnerable" => true, "criteria" => "cpe:2.3:a:php:php:*:*:*:*:*:*:*:*", "versionStartIncluding" => "8.3.0", "versionEndExcluding" => "8.3.36" },
        { "vulnerable" => true, "criteria" => "cpe:2.3:a:php:php:*:*:*:*:*:*:*:*", "versionStartIncluding" => "8.4.0", "versionEndExcluding" => "8.4.27" },
        { "vulnerable" => false, "criteria" => "cpe:2.3:o:debian:debian_linux:12:*:*:*:*:*:*:*" }
      ] } ] } ]
    } } ]
  }.freeze

  setup do
    @requests = []
    Web.resolver = ->(_host) { [ "93.184.216.34" ] }
    Web.transport = lambda do |_verb, uri, _address, _body, _headers|
      @requests << uri.to_s
      [ 200, @answer.to_json, { "content-type" => "application/json" } ]
    end
    @skipsy, _ = agent("skipsy", clearance: "personal")
  end

  teardown do
    Web.transport = nil
    Web.resolver = nil
    ENV.delete("HOB_WARD_CVE_LOOKUP")
  end

  test "NVD fills the component, fixed versions per branch, and known exploitation; its severity is only evidence" do
    assert_equal({ "kev_added" => "2026-10-20", "kev_action_due" => "2026-11-10", "feed_severity" => "critical",
                   "products" => [ "php" ], "fixed_versions" => { "8.3" => "8.3.36", "8.4" => "8.4.27" } },
                 Ward::Enrich.parse(NVD_ANSWER))

    @answer = NVD_ANSWER
    threat, _ = Ward::Threats.report!({ "kind" => "cve", "cve_ids" => [ "CVE-2026-109618" ] }, by: @skipsy)
    assert_empty @requests, "off unless HOB_WARD_CVE_LOOKUP names nvd"
    assert_nil threat.component

    ENV["HOB_WARD_CVE_LOOKUP"] = "nvd"
    threat, _ = Ward::Threats.report!({ "kind" => "cve", "cve_ids" => [ "CVE-2026-109619" ], "title" => "the other one" }, by: @skipsy)
    assert_equal [ "https://services.nvd.nist.gov/rest/json/cves/2.0?cveId=CVE-2026-109619" ], @requests
    assert_equal "php", threat.component
    assert_equal({ "8.3" => "8.3.36", "8.4" => "8.4.27" }, threat.fixed_versions)
    assert threat.exploited?, "CISA's KEV date, carried by NVD, is evidence of exploitation"
    assert_equal "critical", threat.enrichment.dig("cves", "CVE-2026-109619", "feed_severity")
    assert_equal "none", threat.assessed_severity, "nothing in the inventory runs php: the feed's critical is not ward's"
    assert_match(/known exploited, NVD critical; filled component, fixed_versions, exploited/, threat.events.find_by!(kind: "enrichment").body)
  end

  test "NVD trouble is recorded, not raised" do
    ENV["HOB_WARD_CVE_LOOKUP"] = "nvd"
    Web.transport = ->(*) { [ 503, "busy", { "content-type" => "text/plain" } ] }
    threat, _ = Ward::Threats.report!({ "kind" => "cve", "cve_ids" => [ "CVE-2026-109618" ], "component" => "php" }, by: @skipsy)
    assert_equal "HTTP 503", threat.enrichment.dig("cves", "CVE-2026-109618", "error")
    assert_equal "resolved", threat.status
  end

  test "the upstream watch: newest past what runs and at or past the fix; prereleases only when what runs is one" do
    pick = ->(tags, current: nil, fixed: nil) { Ward::Upstream.pick(tags, current: current, fixed: fixed)&.fetch("tag") }
    assert_equal "v4.0.0-beta.422", pick.call(%w[v4.0.0-beta.420 v4.0.0-beta.422 v4.0.0-beta.421 latest], current: "4.0.0-beta.420")
    assert_nil pick.call(%w[v4.0.0-beta.420 v4.0.0-beta.419], current: "4.0.0-beta.420")
    assert_equal "8.3.36-fpm", pick.call(%w[8.3.35-fpm 8.3.36-fpm 8.4.0RC1 latest], fixed: "8.3.36")
    assert_nil pick.call(%w[8.3.35-fpm 8.4.0-rc.1], fixed: "8.3.36"), "a release line is not satisfied by a prerelease"

    spec = Ward::Upstream.normalize!({ "source" => "dockerhub", "repository" => "php", "fixed" => "8.3.36" })
    assert_equal({ "source" => "dockerhub", "repository" => "library/php", "fixed" => "8.3.36", "poll_hours" => 6 }, spec)
    assert_raises(Ward::Invalid) { Ward::Upstream.normalize!({ "source" => "quay", "repository" => "x/y", "fixed" => "1" }) }
    assert_raises(Ward::Invalid) { Ward::Upstream.normalize!({ "source" => "github", "repository" => "coollabsio/coolify" }) }

    @answer = { "results" => [ { "name" => "8.3.36-fpm" }, { "name" => "8.3.35-fpm" } ] }
    assert_equal "8.3.36-fpm", Ward::Upstream.poll(spec)["tag"]
    assert_equal [ "https://hub.docker.com/v2/repositories/library/php/tags?page_size=100&ordering=last_updated" ], @requests

    Web.transport = ->(*) { [ 404, "{}", { "content-type" => "application/json" } ] }
    assert_raises(Ward::Error) { Ward::Upstream.poll(spec) }
  end
end
