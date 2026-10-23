module Sentinel
  module Native
    # ward.threat.accept_risk (THREATS.md): stand a threat down as a risk the
    # household lives with. A person always confirms.
    class WardThreatAcceptRisk < WardThreatHandler
      CAPABILITY = {
        "name" => "ward.threat.accept_risk",
        "description" => "Ask to accept a threat as a known risk, with the person's reason. A person always confirms this. " \
                         "An accepted risk never resolves on its own: it re-surfaces every review period (default 30 days) " \
                         "until it is patched or stood down. Returns { threat, notice }.",
        "kind" => "act",
        "realm" => "personal",
        "requires_person" => true,
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "threat" => THREAT, "reason" => REASON,
            "review_days" => { "type" => "integer", "minimum" => 1, "maximum" => 365 }
          },
          "required" => %w[threat reason],
          "additionalProperties" => false
        }
      }.freeze

      def call
        threat = threat!
        invalid! { Ward::Threats.accept_risk!(threat, reason: arguments["reason"], by: decider, review_days: arguments["review_days"]) }
        answer(threat)
      end
    end
  end
end
