module Sentinel
  # Policy, applied to one request, in order: the capability's realm, the
  # resolved rule's effect, its argument constraints, its limits, then — for
  # `review` — the reviewer. Fails closed: no rule means deny.
  class Gate
    def initialize(request)
      @request = request
      @agent = request.principal
      @capability = request.capability
    end

    def evaluate
      if Realm.rank_of(@request.realm) < @capability.realm_rank
        return deny("realm", "#{@capability.name} needs #{@capability.realm} clearance; the agent has #{@request.realm}")
      end

      rule = SentinelPolicy.resolve(principal: @agent, capability: @capability.name)
      return deny("policy", "no policy permits #{@agent.name} to use #{@capability.name}") if rule.nil?
      return deny("policy", rule_label(rule)) if rule.effect == "deny"

      if (problem = constraint_violation(rule))
        return deny("constraint", problem)
      end
      if (problem = limit_exceeded(rule))
        return deny("limit", problem)
      end

      case rule.effect
      when "allow" then Verdict.new(decision: "allow", decided_by: "policy", rationale: rule_label(rule))
      when "confirm" then Verdict.new(decision: "escalate", decided_by: "policy", rationale: "#{rule_label(rule)}: a person must confirm")
      when "review" then Reviewer.new(@request, rule).call
      end
    end

    private

    def deny(by, rationale)
      Verdict.new(decision: "deny", decided_by: by, rationale: rationale)
    end

    def rule_label(rule)
      "#{rule.effect} by #{rule.for_every_agent? ? 'the default' : @agent.name} rule for #{rule.capability}"
    end

    # constraints: { arg => [allowed] | { in:, max:, pattern: } }
    def constraint_violation(rule)
      rule.constraints.each do |arg, spec|
        spec = { "in" => spec } if spec.is_a?(Array)
        value = @request.arguments[arg.to_s]
        if spec.key?("in") && !spec["in"].any? { |allowed| allowed == value || allowed.to_s == value.to_s }
          return "#{arg} must be one of #{spec['in'].join(', ')}, got #{value.inspect}"
        end
        if spec.key?("max") && !value.nil? && measure(value) > spec["max"]
          return "#{arg} exceeds #{spec['max']}"
        end
        if spec.key?("pattern") && !value.to_s.match?(Regexp.new(spec["pattern"]))
          return "#{arg} does not match #{spec['pattern']}"
        end
      end
      nil
    end

    def measure(value)
      case value
      when Numeric then value
      when String, Array, Hash then value.size
      else 0
      end
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
