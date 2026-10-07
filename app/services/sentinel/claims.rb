module Sentinel
  # User-authorization claims (SENTINEL.md): an agent attaching "the user
  # already said yes in chat" to a request that a `confirm` rule would
  # otherwise always escalate to a person. hob cannot cryptographically
  # verify a chat quote, so the design is deterrence plus audit plus
  # spot-checks — fabrication is attributable, logged, and eventually
  # caught, not structurally prevented.
  #
  # Only Sentinel::Gate's `confirm` branch ever consults a claim: it never
  # lowers the realm/policy/constraint/limit gates above it, and never
  # touches a capability that `requires_person?` — that guarantee holds
  # against an admin's own `allow` rule (SentinelPolicy), so it certainly
  # holds against an unverifiable chat quote.
  #
  # Every claim is logged exactly once, whatever came of it:
  #   rejected       intake failed outright — missing a required field, a
  #                  quote older than the freshness window, or an agent
  #                  outside KNOWN_AGENTS. Treated as if no claim was given.
  #   unused         intake passed, but the rule's effect was never `confirm`
  #                  (nothing to skip).
  #   insufficient   the rubric failed at least one check: escalated to a
  #                  person exactly as without a claim.
  #   backed         the rubric passed and no spot-check fired: the request
  #                  is allowed on the claim's strength alone.
  #   spot_checked   the rubric passed but a spot-check fired: escalated to
  #                  a person, same as a `confirm` rule, with the quote in
  #                  the rationale for them to say yes or no to. Settles when
  #                  they decide (Sentinel.decide!): allow is confirmed, a plain
  #                  deny is declined (the quote may be real; they just don't
  #                  want it done now), and only a deny that says the quote is
  #                  false is fabricated.
  module Claims
    module_function

    # Agents allowed to attach a claim at all. Anyone else's claim is
    # rejected outright — logged, never consulted.
    KNOWN_AGENTS = %w[skipsy marley].freeze

    REQUIRED_FIELDS = %w[quote quoted_at context interpretation action_ref].freeze

    DEFAULT_HIGH_STAKES = %w[
      mail.send mail.reply budget.transaction.create budget.transaction.update
      hob.mission.create hob.schedule.create hob.schedule.cancel calendar.push todo.drop
    ].freeze

    # --- tunables (SENTINEL.md): env vars, so a household can tighten or
    # loosen these without a deploy. -----------------------------------

    def freshness_window
      ENV.fetch("HOB_CLAIM_FRESHNESS_MINUTES", "60").to_i.minutes
    end

    def spot_check_rate
      ENV.fetch("HOB_CLAIM_SPOT_CHECK_RATE", "0.05").to_f
    end

    def elevated_scrutiny_count
      ENV.fetch("HOB_CLAIM_ELEVATED_SCRUTINY_COUNT", "20").to_i
    end

    def high_stakes_capabilities
      raw = ENV["HOB_CLAIM_HIGH_STAKES_CAPABILITIES"]
      (raw.present? ? raw.split(",") : DEFAULT_HIGH_STAKES).map(&:strip)
    end

    # Called only from Sentinel::Gate's `confirm` branch. Always returns a
    # Verdict; always logs exactly one AuthorizationClaim for the raw claim
    # it was handed.
    def decide(request:, rule:, raw:)
      agent = request.principal
      intake = intake!(request: request, raw: raw)
      # Intake never ran the rubric, so nothing was actually decided here:
      # this looks exactly like a `confirm` rule with no claim at all.
      return Verdict.new(decision: "escalate", decided_by: "policy", rationale: "#{rule_label(rule, agent)}: a person must confirm") unless intake.ok?

      claim_fields = intake.attrs
      rubric = Rubric.new(request: request, rule: rule, claim: claim_fields).call

      unless rubric.pass?
        # Only a rubric that actually judged the claim and found it wanting
        # says anything about the agent; a judge that was down or declined
        # is hob's failure, not the agent's.
        agent.start_claim_scrutiny!(elevated_scrutiny_count) if rubric.judged?
        record!(request: request, agent: agent, raw: claim_fields, status: "insufficient", rubric: rubric.to_h)
        return Verdict.new(decision: "escalate", decided_by: "claim",
                           rationale: "a claim was offered but did not hold (#{rubric.failed_checks.join(', ')}): #{rubric.rationale}")
      end

      reason = spot_check_reason(capability: request.capability.name, agent: agent)

      if reason
        claim = record!(request: request, agent: agent, raw: claim_fields, status: "spot_checked", rubric: rubric.to_h,
                        spot_check: { "reason" => reason, "fired_at" => Time.current }, decided: false)
        Verdict.new(decision: "escalate", decided_by: "claim", review: { "claim" => claim.id },
                   rationale: "#{agent.name} claims you authorized this by saying: #{claim_fields['quote'].inspect} " \
                              "(#{claim_fields['quoted_at'].utc.iso8601}). Spot-check (#{reason}): is that right?")
      else
        claim = record!(request: request, agent: agent, raw: claim_fields, status: "backed", rubric: rubric.to_h)
        Verdict.new(decision: "allow", decided_by: "claim", review: { "claim" => claim.id },
                   rationale: "claim held: #{agent.name} says you authorized this by saying #{claim_fields['quote'].inspect}")
      end
    end

    # The rule's effect never reached `confirm` (allow, deny, review, or a
    # requires_person escalate) — the claim was never relevant, but it is
    # still logged, intake-checked, so "did the household see every claim
    # it was handed" has one answer regardless of how the request resolved.
    def log_unused!(request:, raw:)
      intake = intake!(request: request, raw: raw)
      record!(request: request, agent: request.principal, raw: intake.attrs, status: "unused") if intake.ok?
    end

    # Runs intake, logging the claim as rejected when it fails. -> Intake::Result
    def intake!(request:, raw:)
      intake = Intake.call(agent: request.principal, raw: raw)
      unless intake.ok?
        record!(request: request, agent: request.principal, raw: intake.attrs, status: "rejected", rejection_reason: intake.error)
      end
      intake
    end

    # A person settled a spot-checked request (Sentinel.decide!). Allow
    # confirms the claim. Deny alone only declines the action — the quote
    # may well be real — and settles the claim as declined. Only a deny
    # with fabricated: true (the person says they never said it) settles it
    # as fabricated and freezes the agent (SENTINEL.md, "Trust consequences").
    def resolve_spot_check!(claim, decision:, decider:, fabricated: false)
      status =
        if decision == "allow" then "confirmed"
        elsif fabricated then "fabricated"
        else "declined"
        end
      now = Time.current
      claim.update!(status: status, decided_at: now,
                    spot_check: claim.spot_check.merge("resolved_by" => decider.name, "resolved_at" => now))
      return unless status == "fabricated"

      claim.principal.freeze_capabilities!(
        reason: "fabricated claim on request #{claim.sentinel_request_id}: #{decider.name} said they never said " \
                "#{claim.quote.inspect}"
      )
      claim.principal.start_claim_scrutiny!(elevated_scrutiny_count)
    end

    # High stakes comes first, so a request that would be spot-checked
    # anyway never spends one of the agent's owed elevated-scrutiny checks.
    def spot_check_reason(capability:, agent:)
      return "high_stakes" if high_stakes_capabilities.include?(capability)
      return "elevated_scrutiny" if agent.consume_claim_scrutiny!
      return "random" if rand < spot_check_rate

      nil
    end

    def rule_label(rule, agent)
      "#{rule.effect} by #{rule.for_every_agent? ? 'the default' : agent.name} rule for #{rule.capability}"
    end

    # decided: false for a spot-check, which a person has yet to settle.
    def record!(request:, agent:, raw:, status:, rejection_reason: nil, rubric: {}, spot_check: {}, decided: true)
      AuthorizationClaim.create!(
        principal: agent, sentinel_request: request, realm: request.realm, status: status, rejection_reason: rejection_reason,
        quote: raw["quote"], quoted_at: raw["quoted_at"], context: raw["context"],
        interpretation: raw["interpretation"], action_ref: raw["action_ref"],
        rubric: rubric, spot_check: spot_check, decided_at: (Time.current if decided)
      )
    end

    # Deterministic checks a claim must pass before the rubric ever runs:
    # a known agent, every required field present, and a quote inside the
    # freshness window. -> Result(#ok?, #attrs, #error)
    class Intake
      Result = Struct.new(:ok, :attrs, :error, keyword_init: true) do
        def ok?
          !!ok
        end
      end

      def self.call(agent:, raw:)
        new(agent: agent, raw: raw).call
      end

      def initialize(agent:, raw:)
        @agent = agent
        @shape_ok = raw.nil? || raw.is_a?(Hash)
        @raw_class = raw.class.name.downcase
        @raw = @shape_ok ? (raw || {}).to_h.stringify_keys : {}
      end

      def call
        return reject("user_authorization must be an object, not #{@raw_class}") unless @shape_ok
        return reject("#{@agent.name} is not a known claimant") unless KNOWN_AGENTS.include?(@agent.name)

        missing = REQUIRED_FIELDS.select { |field| @raw[field].to_s.strip.blank? }
        return reject("missing #{missing.join(', ')}") if missing.any?

        quoted_at = parse_time(@raw["quoted_at"])
        return reject("quoted_at #{@raw['quoted_at'].inspect} is not a valid timestamp") if quoted_at.nil?
        return reject("quoted_at is in the future") if quoted_at > Time.current + 1.minute
        if quoted_at < Claims.freshness_window.ago
          return reject("quote is from #{quoted_at.utc.iso8601}, older than the #{Claims.freshness_window.inspect} freshness window")
        end

        Result.new(ok: true, attrs: @raw.merge("quoted_at" => quoted_at), error: nil)
      end

      private

      def reject(message)
        Result.new(ok: false, attrs: @raw, error: message)
      end

      def parse_time(value)
        Time.iso8601(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
