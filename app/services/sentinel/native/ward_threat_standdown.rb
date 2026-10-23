module Sentinel
  module Native
    # ward.threat.standdown (THREATS.md): end an actor watch early. A person
    # always confirms.
    class WardThreatStanddown < WardThreatHandler
      CAPABILITY = {
        "name" => "ward.threat.standdown",
        "description" => "Ask to end an actor threat's watch before its window runs out, with the person's reason. A " \
                         "person always confirms this. The threat resolves as stood down and the raised scan cadence " \
                         "ends. Returns { threat, notice }.",
        "kind" => "act",
        "realm" => "personal",
        "requires_person" => true,
        "input_schema" => {
          "type" => "object",
          "properties" => { "threat" => THREAT, "reason" => REASON },
          "required" => %w[threat reason],
          "additionalProperties" => false
        }
      }.freeze

      def call
        threat = threat!
        invalid! { Ward::Threats.standdown!(threat, reason: arguments["reason"], by: decider) }
        answer(threat)
      end
    end
  end
end
