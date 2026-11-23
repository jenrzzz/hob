module Sentinel
  # Policy, applied to one request, in order: the capability's realm, the
  # resolved rule's effect, its argument constraints, its limits, then — for
  # `review` — the reviewer. Fails closed: no rule means deny.
  class Gate
    def initialize(request, user_authorization: nil)
      @request = request
      @agent = request.principal
      @capability = request.capability
      @claim = user_authorization
      @claim_consumed = false
    end

    def evaluate
      verdict = resolve
      Claims.log_unused!(request: @request, raw: @claim) if @claim.present? && !@claim_consumed
      verdict
    end

    private

    def resolve
      if @agent.capabilities_frozen?
        return deny("claim", "#{@agent.name}'s capabilities are frozen pending review: #{@agent.capabilities_freeze_reason}")
      end
      # A quarantined plugin installation, or a personal one that is not the
      # caller's, is out of reach whatever a rule says (PLUGINS.md, section 4).
      if (problem = @capability.unavailable_to(@agent))
        return deny("plugin", problem)
      end
      # A capability a surface proposed on its own reaches nobody, whatever
      # rule (a wildcard, say) would match it, until a person accepts it.
      unless @capability.accepted?
        return deny("policy", "#{@capability.name} is waiting for a person to accept it")
      end
      if Realm.rank_of(@request.realm) < @capability.realm_rank
        return deny("realm", "#{@capability.name} needs #{@capability.realm} clearance; the agent has #{@request.realm}")
      end

      rule = SentinelPolicy.resolve(principal: @agent, capability: @capability.name)
      return deny("policy", "no policy permits #{@agent.name} to use #{@capability.name}") if rule.nil?
      return deny("policy", rule_label(rule)) if rule.effect == "deny"

      if (problem = rule.violation(@request.arguments, realm: @request.realm))
        return deny("constraint", "#{problem}#{petition_hint(rule)}")
      end
      if (problem = limit_exceeded(rule))
        return deny("limit", problem)
      end

      if @capability.requires_person? && %w[allow review].include?(rule.effect)
        return Verdict.new(decision: "escalate", decided_by: "policy",
                           rationale: "#{rule_label(rule)}, but only a person may approve #{@capability.name}: a person must confirm")
      end

      case rule.effect
      when "allow" then Verdict.new(decision: "allow", decided_by: "policy", rationale: rule_label(rule))
      when "confirm"
        # requires_person? is the one guarantee nothing but a person
        # loosens (it holds even against an admin's own `allow` rule,
        # above) — an unverifiable chat quote certainly doesn't get to.
        if @claim.present? && !@capability.requires_person?
          @claim_consumed = true
          Claims.decide(request: @request, rule: rule, raw: @claim)
        else
          Verdict.new(decision: "escalate", decided_by: "policy", rationale: "#{rule_label(rule)}: a person must confirm")
        end
      when "review" then Reviewer.new(@request, rule).call
      end
    end

    def deny(by, rationale)
      Verdict.new(decision: "deny", decided_by: by, rationale: rationale)
    end

    # A constraint is the scope of a grant, and scope can be petitioned for:
    # say so, or the agent reads the refusal as final (skipsy and fsa-claims,
    # 2026-11-07). Only the agent's own exact rule is re-grantable this way.
    def petition_hint(rule)
      return "" unless rule.principal_id == @agent.id && rule.specificity == 2

      ". To widen this grant's scope, petition (sentinel_petition, or POST /v1/sentinel/petitions) for #{rule.capability}, " \
        "saying what you need it to cover and why"
    end

    def rule_label(rule)
      "#{rule.effect} by #{rule.for_every_agent? ? 'the default' : @agent.name} rule for #{rule.capability}"
    end

    # limits: { per_hour:, per_day: } count this agent's non-denied requests
    # for capabilities the rule covers; cost_per_day is the agent's whole
    # sentinel spend in the ledger over the last day.
    def limit_exceeded(rule)
      limits = rule.limits
      return nil if limits.blank?

      { "per_hour" => 1.hour, "per_day" => 1.day }.each do |key, window|
        next unless limits[key]

        used = @agent.sentinel_requests.counted.since(window.ago).where.not(id: @request.id)
                     .includes(:capability).count { |r| rule.matches?(r.capability.name) }
        return "#{key} limit of #{limits[key]} reached for #{rule.capability}" if used >= limits[key]
      end

      if limits["cost_per_day"]
        spent = UsageEvent.where(principal: @agent).since(1.day.ago).where("ref LIKE 'sentinel/%'").sum(:cost).to_f
        return format("daily sentinel spend of $%.4f reached the $%.4f limit", spent, limits["cost_per_day"]) if spent >= limits["cost_per_day"]
      end
      nil
    end
  end
end
