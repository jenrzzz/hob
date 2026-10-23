module Ward
  # The ward's clock for threats (THREATS.md, "Resolution"): ward decides
  # when a threat is over, and only with evidence it can point at. Runs from
  # WardSweepJob, hourly, after the inventory sync; idempotent and quiet
  # when nothing moved.
  #
  #   cve, advisory   every matched asset at or past the fixed version, seen
  #                   fresh after the threat was reported, on two checks at
  #                   least an hour apart, with every gotcha checked off →
  #                   resolved. A matched asset moving off its version while
  #                   exposed means a fix is underway → mitigating. A resolved
  #                   one whose asset falls back below → reopened at monitoring.
  #   awaiting        the upstream watch polls; when the fix lands, ward stages
  #                   the upgrade for a person
  #   actor           the window ran out with no indicator → expired, and ward
  #                   proposes resolved for a person to confirm or extend
  #   accepted risk   re-surfaces every review period, and resolves like a CVE
  #                   if it gets patched after all
  class Resolver
    VERSIONED = %w[exposed awaiting_upstream mitigating monitoring accepted_risk resolved].freeze

    def self.call(now: Time.current)
      new(now: now).call
    end

    def initialize(now:)
      @now = now
    end

    # -> [[threat id, what happened], ...]
    def call
      moved = []
      WardThreat.where(kind: %w[cve advisory], status: VERSIONED).find_each do |threat|
        what = versions(threat)
        moved << [ threat.id, what ] if what
      rescue StandardError => e
        Rails.logger.error("ward resolver, threat #{threat.id}: #{e.class}: #{e.message}")
      end
      WardThreat.where(status: "awaiting_upstream").where.not(upstream: nil).find_each do |threat|
        what = upstream(threat)
        moved << [ threat.id, what ] if what
      end
      WardThreat.where(kind: "actor", status: "monitoring").where(expires_at: ..@now).find_each do |threat|
        threat.move!("expired", body: "the window ended with no indicators")
        Posture.expired(threat)
        moved << [ threat.id, "expired" ]
      end
      WardThreat.where(status: "accepted_risk").where(review_at: ..@now).find_each do |threat|
        threat.update!(review_at: @now + review_every)
        threat.record!("review", body: "accepted risk re-surfaced for review; next #{threat.review_at.utc.to_date}")
        Posture.review(threat)
        moved << [ threat.id, "reviewed" ]
      end
      moved
    end

    private

    def versions(threat)
      result = Assess.call(threat)
      before = threat.affected
      threat.update!(affected: result.affected, assessed_severity: result.severity, confidence: result.confidence) if before != result.affected

      case threat.status
      when "resolved" then regression(threat, result)
      when "monitoring", "accepted_risk" then sustain(threat, result)
      when "mitigating" then first_pass(threat, result, "monitoring")
      when "exposed", "awaiting_upstream"
        return first_pass(threat, result, "monitoring") if result.all_fixed? && fresh?(threat, result)

        if moved_versions?(before, result.affected)
          threat.move!("mitigating", body: "a matched asset's version changed: #{changes(before, result.affected)}")
          "mitigating"
        end
      end
    end

    # The fix is everywhere, seen since the threat was reported: the first
    # passing check, and into monitoring.
    def first_pass(threat, result, to)
      return nil unless result.all_fixed? && fresh?(threat, result)

      pass!(threat, result)
      threat.move!(to, body: "every matched asset at or past the fixed version") if threat.status != to
      to
    end

    # A second check at least an hour after the first, on observations
    # refreshed since it, resolves; anything below the fixed version
    # starts the count over.
    def sustain(threat, result)
      unless result.all_fixed?
        return nil if threat.passes.empty?

        threat.update!(passes: [])
        threat.record!("pass", body: "check failed: #{result.summary}; passes reset", data: { "ok" => false })
        return "reset"
      end

      last = threat.passes.last && Time.zone.parse(threat.passes.last["at"])
      return (pass!(threat, result) && "pass") if last.nil? && fresh?(threat, result)
      return nil if last.nil? || last > @now - WardThreat::SUSTAIN || !fresh?(threat, result, since: last)

      pass!(threat, result)
      return nil if threat.passes.size < WardThreat::PASSES

      if (pending = threat.unsatisfied_gotchas).any?
        waiting = "waiting on #{pending.map { |g| "gotcha #{g['index']} (#{g['text']})" }.join(', ')}"
        threat.record!("note", body: waiting) unless threat.events.where(kind: "note", body: waiting).exists?
        return nil
      end

      threat.move!("monitoring", body: "patched after being accepted") if threat.status == "accepted_risk"
      Threats.resolve!(threat, criteria: "every matched asset at or past the fixed version, on #{threat.passes.size} checks ≥#{WardThreat::SUSTAIN.inspect} apart",
                               evidence: { "passes" => threat.passes, "gotchas" => threat.gotchas.presence }.compact)
      "resolved"
    end

    def regression(threat, result)
      unmatched = threat.resolution&.dig("evidence", "matched") == false
      if unmatched && result.matched
        why = "the inventory now matches: #{result.summary}"
      elsif result.vulnerable.any?
        why = "regression: #{result.vulnerable.map { |a| "#{a['name']} #{a['component']} #{a['version']}" }.join(', ')} below the fixed version"
      else
        return nil
      end

      threat.update!(passes: [], resolution: nil)
      threat.move!("monitoring", body: why)
      Posture.reopened(threat, why)
      "reopened"
    end

    def upstream(threat)
      spec = threat.upstream
      return nil unless Upstream.due?(spec, now: @now)

      landed = Upstream.poll(spec)
      threat.update!(upstream: spec.merge("last_polled_at" => @now.utc.iso8601, "landed" => landed, "error" => nil).compact)
      return nil if landed.nil?

      threat.record!("upstream", body: "fix landed upstream: #{spec['repository']} #{landed['tag']}", data: landed)
      Posture.landed(threat, landed)
      "landed"
    rescue Ward::Error => e
      threat.update!(upstream: spec.merge("last_polled_at" => @now.utc.iso8601, "error" => e.message.truncate(300)))
      nil
    end

    def pass!(threat, result)
      evidence = result.affected.map { |a| a.slice("name", "component", "version", "source", "observation", "seen_at") }
      threat.update!(passes: threat.passes + [ { "at" => @now.utc.iso8601, "evidence" => evidence } ])
      threat.record!("pass", body: "check #{threat.passes.size}: #{result.summary}", data: { "ok" => true, "evidence" => evidence })
    end

    # Every matched asset's version seen since `since` (the threat's report,
    # or the previous pass): a fresh probe, not a remembered one.
    def fresh?(threat, result, since: threat.created_at)
      result.affected.all? { |a| a["seen_at"].present? && Time.zone.parse(a["seen_at"]) > since }
    end

    def moved_versions?(before, after)
      was = before.to_h { |a| [ a["asset"], a["version"] ] }
      after.any? { |a| was.key?(a["asset"]) && was[a["asset"]] != a["version"] }
    end

    def changes(before, after)
      was = before.to_h { |a| [ a["asset"], a["version"] ] }
      after.select { |a| was.key?(a["asset"]) && was[a["asset"]] != a["version"] }
           .map { |a| "#{a['name']} #{a['component']} #{was[a['asset']] || '?'} → #{a['version'] || '?'}" }.join(", ")
    end

    def review_every
      (ENV["HOB_WARD_REVIEW_DAYS"].presence&.to_i || WardThreat::REVIEW_EVERY.in_days.to_i).days
    end
  end
end
