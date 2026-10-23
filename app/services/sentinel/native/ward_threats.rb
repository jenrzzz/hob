module Sentinel
  module Native
    # ward.threats (THREATS.md): the threats the ward holds, or one with its
    # history. Reads only.
    class WardThreats < WardThreatHandler
      CAPABILITY = {
        "name" => "ward.threats",
        "description" => "List the ward's threats (open by default), or get one with its whole history by `threat`. " \
                         "Returns { threats: [{ id, kind, title, status, cve_ids, assessed_severity, confidence, " \
                         "expires_at, updated_at }] } or { threat: #{THREAT_JSON} }, with a notice. Read-only.",
        "kind" => "read",
        "realm" => "personal",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "threat" => THREAT,
            "state" => { "enum" => %w[open closed all] + WardThreat::STATUSES, "default" => "open" },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 100, "default" => 50 }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        if arguments["threat"].present?
          return { "threat" => threat!.as_json_for_ward(history: true), "notice" => Ward::Threats::NOTICE }
        end

        rows = invalid! { WardThreat.in_state(arguments["state"]) }.by_severity.limit((arguments["limit"] || 50).to_i.clamp(1, 100))
        { "threats" => Ward::Threats.as_list(rows), "notice" => Ward::Threats::NOTICE }
      end
    end
  end
end
