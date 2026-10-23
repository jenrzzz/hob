module Ward
  # Triage for a threat (THREATS.md): join what it names against what the
  # ward knows the household runs, and say where that leaves it. Pure: it
  # reads the inventory and the threat and changes neither.
  #
  #   a matched asset below the fixed version   → exposed
  #   every matched asset at or past it         → not_exposed, with the versions as evidence
  #   nothing in the inventory matches          → not_exposed (unmatched), said as such
  #   a match whose version is not known        → exposed (unverified)
  #   an actor                                  → monitoring, over the public surface
  #
  # Severity is ward's own: exploitability (known exploited, from a feed or a
  # person) times exposure (public > tailnet > localhost). A reporter's
  # claimed severity is a starting point that can never reach critical on
  # its own, and a feed's severity is evidence, never the answer.
  class Assess
    Result = Struct.new(:status, :affected, :severity, :confidence, :summary, :matched, keyword_init: true) do
      def vulnerable
        affected.select { |a| a["verdict"] == "vulnerable" }
      end

      def unknown
        affected.select { |a| a["verdict"] == "unknown" }
      end

      def all_fixed?
        matched && affected.any? && affected.all? { |a| a["verdict"] == "fixed" }
      end
    end

    SURFACE_LIMIT = 30

    def self.call(threat)
      new(threat).call
    end

    def initialize(threat)
      @threat = threat
    end

    def call
      case @threat.kind
      when "cve", "advisory" then versions
      when "actor" then surface
      when "anomaly" then anomaly
      end
    end

    private

    def versions
      component = @threat.component.to_s.downcase
      if component.blank?
        return Result.new(status: "not_exposed", affected: [], severity: "none", confidence: "unverified", matched: false,
                          summary: "unmatched: the threat names no component to look for, and the inventory is known to be incomplete")
      end

      assets = WardAsset.present.with_component(component).by_name.to_a
      if assets.empty?
        return Result.new(status: "not_exposed", affected: [], severity: "none", confidence: "unverified", matched: false,
                          summary: "unmatched: nothing in the inventory runs #{component} (#{WardAsset.present.count} assets known; the inventory is known to be incomplete)")
      end

      affected = assets.map { |asset| entry(asset, component) }
      result = Result.new(affected: affected, matched: true)
      if result.vulnerable.any?
        result.status = "exposed"
        result.confidence = "verified"
        result.summary = "exposed: #{names(result.vulnerable)} below the fixed version"
      elsif result.unknown.any?
        result.status = "exposed"
        result.confidence = "unverified"
        result.summary = "exposed (unverified): #{names(result.unknown)} run #{component}, version not known"
      else
        result.status = "not_exposed"
        result.confidence = "verified"
        result.summary = "not exposed: #{names(affected)} at or past the fixed version"
      end
      result.severity = cve_severity(affected)
      result
    end

    def entry(asset, component)
      version, observation, disagreement = asset.believed(component)
      verdict, why = Versions.verdict(version, @threat.fixed_versions)
      {
        "asset" => asset.id, "name" => asset.name, "host" => asset.host, "kind" => asset.kind, "component" => component,
        "version" => version, "verdict" => verdict, "why" => why, "exposure" => asset.effective_exposure,
        "observation" => observation&.id, "source" => observation&.source, "seen_at" => observation&.last_seen_at&.utc&.iso8601,
        "disagreement" => disagreement
      }.compact
    end

    def names(entries)
      entries.map { |a| a["version"] ? "#{a['name']} (#{a['component']} #{a['version']})" : a["name"] }.join(", ")
    end

    def cve_severity(affected)
      at_risk = affected.reject { |a| a["verdict"] == "fixed" }
      return "none" if at_risk.empty?

      rank = WardThreat::SEVERITIES.index(base_severity)
      # An asset whose exposure ward does not know is weighed as public.
      distance = at_risk.map { |a| WardAsset::EXPOSURE_RANK.fetch(a["exposure"].to_s, 0) }.min
      WardThreat::SEVERITIES[(rank - distance).clamp(1, 4)]
    end

    # Known exploited is critical; otherwise the claim, capped at high.
    def base_severity
      return "critical" if @threat.exploited?

      claimed = @threat.claimed_severity.presence || "high"
      WardThreat::SEVERITIES.index(claimed) > WardThreat::SEVERITIES.index("high") ? "high" : claimed
    end

    # An actor names a surface, or the whole public face of the house. There
    # is no version to check: the surface is what ward watches more closely.
    def surface
      assets = targeted_assets
      assets = WardAsset.present.where(exposure: "public").or(WardAsset.present.where("declared->>'exposure' = 'public'")).by_name.to_a if assets.empty?
      affected = assets.first(SURFACE_LIMIT).map do |asset|
        { "asset" => asset.id, "name" => asset.name, "host" => asset.host, "kind" => asset.kind, "exposure" => asset.effective_exposure }.compact
      end
      findings = WardFinding.unresolved.by_severity.limit(SURFACE_LIMIT).map do |f|
        { "finding" => f.id, "name" => f.subject, "message" => f.message, "state" => f.state }
      end
      indicators = @threat.persisted? && @threat.events.where(kind: "indicator").exists?
      Result.new(status: "monitoring", affected: affected + findings, matched: assets.any?, confidence: nil,
                 # A stranger's words alone never raise this past medium; indicators ward observed do.
                 severity: indicators ? "high" : capped(@threat.claimed_severity, "medium"),
                 summary: "watching #{assets.size} public asset#{'s' unless assets.size == 1} and #{findings.size} unresolved finding#{'s' unless findings.size == 1}" \
                          "#{" for #{@threat.target}" if @threat.target.present?}")
    end

    def anomaly
      assets = targeted_assets
      affected = assets.map { |asset| { "asset" => asset.id, "name" => asset.name, "host" => asset.host, "exposure" => asset.effective_exposure }.compact }
      distance = affected.map { |a| WardAsset::EXPOSURE_RANK.fetch(a["exposure"].to_s, 0) }.min || 0
      rank = WardThreat::SEVERITIES.index(@threat.claimed_severity.presence || "medium")
      Result.new(status: "exposed", affected: affected, matched: assets.any?, confidence: assets.any? ? "verified" : "unverified",
                 severity: WardThreat::SEVERITIES[(rank - distance).clamp(1, 4)],
                 summary: assets.any? ? "anomaly on #{names(affected)}" : "anomaly on #{@threat.target.presence || 'an unnamed surface'}; not in the inventory")
    end

    def targeted_assets
      target = @threat.target.to_s.strip.downcase
      return [] if target.blank?

      WardAsset.present.where("lower(name) = :t OR lower(host) = :t OR lower(ref) = :t", t: target).by_name.to_a
    end

    def capped(severity, cap)
      severity = severity.presence || cap
      WardThreat::SEVERITIES.index(severity) > WardThreat::SEVERITIES.index(cap) ? cap : severity
    end
  end
end
