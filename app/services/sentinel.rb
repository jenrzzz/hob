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
  def submit!(agent:, capability:, arguments: {}, reason: nil, on_mission: nil)
    raise Invalid, "only agents ask the sentinel" unless agent.agent?

    cap = Capability.enabled.find_by(name: capability.to_s)
    raise Invalid, "unknown capability #{capability.inspect}" if cap.nil?

    request = SentinelRequest.create!(
      principal: agent, capability: cap, arguments: (arguments || {}).to_h.deep_stringify_keys,
      reason: reason.presence, surface: Current.surface, realm: Current.clearance,
      on_mission_id: on_mission.presence
    )
    verdict = Gate.new(request).evaluate
    request.decide!(decision: verdict.decision, decided_by: verdict.decided_by, rationale: verdict.rationale,
                    review: verdict.review)
    Executor.run!(request) if request.decision == "allow"
    request
  end

  # A person settles a pending request.
  def decide!(request, decision:, decider:, rationale: nil)
    raise Invalid, "only people decide sentinel requests" unless decider.trusted?
    raise Invalid, "request #{request.id} is #{request.status}, not pending" unless request.pending?
    raise Invalid, "decision must be allow or deny" unless %w[allow deny].include?(decision.to_s)

    request.decide!(decision: decision.to_s, decided_by: "human", rationale: rationale.presence, decider: decider)
    Executor.run!(request) if request.decision == "allow"
    request
  end
end
