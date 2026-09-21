module Mcp
  module Tools
    # ward.ack (WARD.md): a person saying a finding is known and why. The
    # acknowledgement is theirs, so it is recorded as the key's principal.
    class WardAck < Sentinel::Native::Base
      TOOL = {
        "name" => "ward.ack",
        "description" => "Acknowledge a ward finding: it is known, and the note says why it is acceptable or what is being " \
                         "done. An acknowledged finding stops counting as open until it changes, resolves, or `until` " \
                         "passes. This is the person's judgement to make, so ask before acknowledging on their behalf. " \
                         "Returns { finding }.",
        "kind" => "act",
        "realm" => "personal",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "id" => { "type" => "string", "description" => "A finding id from ward_findings or ward_status" },
            "note" => { "type" => "string", "description" => "Why this is acceptable, in the person's words" },
            "until" => { "type" => "string", "description" => "When the acknowledgement lapses (ISO8601, in the future); default: never" }
          },
          "required" => %w[id],
          "additionalProperties" => false
        }
      }.freeze

      def call
        finding = WardFinding.find(require_argument(:id))
        finding.acknowledge!(by: request.principal, note: arguments["note"], until_at: until_at)
        { "finding" => finding.as_json_for_ward }
      end

      private

      def until_at
        return nil if arguments["until"].blank?

        Time.zone.parse(arguments["until"].to_s) || raise(ArgumentError)
      rescue ArgumentError
        raise Ward::Invalid, "until must be an ISO8601 date-time"
      end
    end
  end
end
