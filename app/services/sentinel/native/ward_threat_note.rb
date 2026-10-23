module Sentinel
  module Native
    # ward.threat.note (THREATS.md): add evidence or context to a threat's
    # history, with your name on it.
    class WardThreatNote < WardThreatHandler
      CAPABILITY = {
        "name" => "ward.threat.note",
        "description" => "Add a note to a threat's history: evidence, context, what you saw. `indicator: true` says it is " \
                         "a sign the threat is live (a probe from the named source, an auth failure): on an actor watch " \
                         "it resets the window and the household is told. Notes are kept, never edited. Returns { threat, " \
                         "event: { id, kind, at, by, body }, notice }.",
        "kind" => "act",
        "realm" => "personal",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "threat" => THREAT,
            "body" => { "type" => "string", "maxLength" => Ward::Threats::NOTE_LIMIT },
            "evidence" => { "type" => "string", "maxLength" => 500, "description" => "Where it can be checked: a URL, a mail id, a log line" },
            "indicator" => { "type" => "boolean" }
          },
          "required" => %w[threat body],
          "additionalProperties" => false
        }
      }.freeze

      def call
        threat = threat!
        event = invalid! do
          Ward::Threats.note!(threat, body: arguments["body"], by: request.principal, evidence: arguments["evidence"],
                                      indicator: arguments["indicator"] == true)
        end
        answer(threat.reload, event: event.as_json_for_ward)
      end
    end
  end
end
