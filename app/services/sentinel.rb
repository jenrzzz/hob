# The sentinel (SENTINEL.md): less-trusted external agents — Muse, or any AI
# that isn't hob's own — ask for information and privileged actions here,
# and never anywhere else. Every ask is a SentinelRequest: policy decides
# (allow / deny / an LLM reviewer / a person), the executor carries out what
# was allowed, and the row is the audit trail.
#
#   Sentinel.submit!(agent:, capability: "hob.complete", arguments: {...}, reason: "...")
#   Sentinel.decide!(request, decision: "allow", decider: jenner, rationale: "fine")
module Sentinel
  class Invalid < Gateway::Invalid; end # 422 through the controller's rescue_from

  Verdict = Struct.new(:decision, :decided_by, :rationale, :review, keyword_init: true)

  module_function

  # An agent's ask, decided and (when allowed) executed, in one call. Always
  # returns the request; read `status` for what happened.
  #
  # user_authorization (SENTINEL.md, "User-authorization claims"): an agent
  # may attach { quote, quoted_at, context, interpretation, action_ref },
  # claiming the household member already authorized this in chat. Only a
  # rule resolving to `confirm` ever consults it; everywhere else it is
  # logged and otherwise ignored.
  def submit!(agent:, capability:, arguments: {}, reason: nil, on_mission: nil, user_authorization: nil)
    raise Invalid, "only agents ask the sentinel" unless agent.agent?

    cap = Capability.enabled.find_by(name: capability.to_s)
    raise Invalid, "unknown capability #{capability.inspect}" if cap.nil?

    request = SentinelRequest.create!(
      principal: agent, capability: cap, arguments: (arguments || {}).to_h.deep_stringify_keys,
      reason: reason.presence, surface: Current.surface, realm: Current.clearance,
      on_mission_id: on_mission.presence
    )
    verdict = Gate.new(request, user_authorization: user_authorization).evaluate
    request.decide!(decision: verdict.decision, decided_by: verdict.decided_by, rationale: verdict.rationale,
                    review: verdict.review)
    Executor.run!(request) if request.decision == "allow"
    ask_person!(request) if request.pending?
    request
  end

  # A person has to look: the household topic and the companion app (Notify).
  def ask_person!(request)
    Notify.person(title: "hob: #{request.principal.name} asks for #{request.capability.name}",
                  body: [ request.reason.presence, request.rationale.presence, decide_hint ].compact.join("\n"),
                  tags: "bell", about: request)
  end

  # Where a person goes to decide: the admin page when hob knows its own URL.
  def decide_hint
    base = ENV["HOB_CLIENT_URL"].presence
    base ? "#{base.chomp('/')}/admin/sentinel" : "bin/rails hob:sentinel:pending"
  end

  # A person settles a pending request. When it was pending because a claim
  # was spot-checked (SENTINEL.md), the same tap also settles the claim:
  # allow confirms it, deny declines it, and deny with fabricated: true
  # says the person never said that — fabrication, and the agent's
  # capabilities freeze. A frozen agent's pending requests can still be
  # denied, but not allowed until a person unfreezes it.
  def decide!(request, decision:, decider:, rationale: nil, fabricated: false)
    raise Invalid, "only people decide sentinel requests" unless decider.trusted?
    raise Invalid, "request #{request.id} is #{request.status}, not pending" unless request.pending?
    raise Invalid, "decision must be allow or deny" unless %w[allow deny].include?(decision.to_s)

    claim = request.authorization_claim
    if fabricated
      raise Invalid, "only a spot-checked claim can be called fabricated" unless claim&.spot_checked?
      raise Invalid, "a fabricated claim can't be allowed" if decision.to_s == "allow"
    end
    if decision.to_s == "allow" && request.principal.capabilities_frozen?
      raise Invalid, "#{request.principal.name}'s capabilities are frozen pending review; unfreeze it before allowing its requests"
    end

    request.decide!(decision: decision.to_s, decided_by: "human", rationale: rationale.presence, decider: decider)
    Executor.run!(request) if request.decision == "allow"
    Claims.resolve_spot_check!(claim, decision: decision.to_s, decider: decider, fabricated: fabricated) if claim&.spot_checked?
    request
  end

  # An agent asks for a capability it does not have: a petition, decided by
  # the steward (SENTINEL.md, "Petitions and the forge"). Always returns the
  # petition; read `status`.
  def petition!(agent:, want:, capability: nil, arguments: {}, reason: nil, on_mission: nil)
    raise Invalid, "only agents petition the sentinel" unless agent.agent?
    raise Invalid, "want is required: what the agent wants to be able to do" if want.blank?
    if capability.present? && !capability.to_s.match?(Capability::NAME_FORMAT)
      raise Invalid, "capability #{capability.inspect} is not a valid name (lowercase dotted words)"
    end

    petition = Petition.create!(
      principal: agent, want: want.to_s.strip.truncate(4000), capability_name: capability.presence,
      arguments: (arguments || {}).to_h.deep_stringify_keys, reason: reason.presence,
      surface: Current.surface, realm: Current.clearance, on_mission_id: on_mission.presence
    )
    Steward.process!(petition)
  end

  # A person settles a pending (or failed) petition: grant, build, or deny.
  def decide_petition!(petition, decision:, decider:, **options)
    Steward.decide!(petition, decision: decision, decider: decider, **options)
  end
end
