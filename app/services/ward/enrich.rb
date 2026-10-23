module Ward
  # CVE enrichment at triage (THREATS.md): ask NVD what it knows about each
  # CVE a threat names, to fill in what the reporter left out. Opt-in, with
  # HOB_WARD_CVE_LOOKUP=nvd, since it is a request to the internet with the
  # household's CVE list in it.
  #
  # What it may fill: the component (the CPE product) and fixed versions per
  # branch (versionEndExcluding), but only where the report had none, and
  # `exploited`, when NVD carries CISA's Known Exploited Vulnerabilities
  # date. NVD's own severity is kept as evidence and never becomes ward's:
  # ward's severity comes from our inventory (Ward::Assess).
  module Enrich
    NVD = "https://services.nvd.nist.gov/rest/json/cves/2.0?cveId=".freeze

    module_function

    def enabled?
      ENV["HOB_WARD_CVE_LOOKUP"].to_s.split(",").map(&:strip).include?("nvd")
    end

    def call(threat)
      return unless enabled? && threat.cve_ids.any?

      found = threat.cve_ids.to_h { |id| [ id, lookup(id) ] }
      products = found.values.flat_map { |f| f["products"] || [] }
      fixed = found.values.map { |f| f["fixed_versions"] || {} }.reduce({}, :merge)
      changes = { enrichment: { "source" => "nvd", "at" => Time.current.utc.iso8601, "cves" => found } }
      changes[:component] = products.tally.max_by(&:last)&.first if threat.component.blank? && products.any?
      changes[:fixed_versions] = fixed if threat.fixed_versions.blank? && fixed.any?
      changes[:exploited] = true if found.values.any? { |f| f["kev_added"] }
      threat.update!(changes)
      threat.record!("enrichment", body: summary(found, changes), data: { "source" => "nvd", "filled" => changes.keys.map(&:to_s) - %w[enrichment] })
    end

    def lookup(id)
      response = Web.get("url" => "#{NVD}#{id}", "headers" => { "Accept" => "application/json" }, "raw" => true, "max_chars" => Web::MAX_CHARS)
      return { "error" => "HTTP #{response['status']}" } unless response["ok"]
      return { "error" => "the answer was too long to read whole" } if response["body_truncated"]

      parse(JSON.parse(response["body"].to_s))
    rescue Web::Error, JSON::ParserError => e
      { "error" => e.message.truncate(200) }
    end

    # One NVD 2.0 answer → { kev_added, feed_severity, products, fixed_versions }.
    def parse(data)
      cve = Array(data["vulnerabilities"]).first&.dig("cve")
      return { "error" => "NVD does not know it" } if cve.nil?

      matches = Array(cve["configurations"]).flat_map { |c| Array(c["nodes"]) }.flat_map { |n| Array(n["cpeMatch"]) }.select { |m| m["vulnerable"] }
      fixed = {}
      products = []
      matches.each do |m|
        parts = m["criteria"].to_s.split(":")
        products << WardAsset.component_name(parts[4]) if parts[4].present?
        fix = m["versionEndExcluding"].presence
        next unless fix

        branch = Versions.parse(m["versionStartIncluding"].presence || fix)&.then { |v| Versions.numeric_segments(v).first(2).join(".") }
        fixed[branch.presence || "*"] = fix
      end
      metric = %w[cvssMetricV40 cvssMetricV31 cvssMetricV30].lazy.filter_map { |k| Array(cve.dig("metrics", k)).first }.first
      {
        "kev_added" => cve["cisaExploitAdd"], "kev_action_due" => cve["cisaActionDue"],
        "feed_severity" => metric&.dig("cvssData", "baseSeverity")&.downcase,
        "products" => products.uniq.presence, "fixed_versions" => fixed.presence
      }.compact
    end

    def summary(found, changes)
      bits = found.map { |id, f| f["error"] ? "#{id}: #{f['error']}" : "#{id}: #{[ ('known exploited' if f['kev_added']), ("NVD #{f['feed_severity']}" if f['feed_severity']) ].compact.join(', ').presence || 'no exploitation on record'}" }
      filled = changes.keys.map(&:to_s) - %w[enrichment]
      "NVD — #{bits.join('; ')}#{"; filled #{filled.join(', ')}" if filled.any?}"
    end
  end
end
