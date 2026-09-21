module Mcp
  module Tools
    # ward.findings (WARD.md): the ledger itself, where ward_status is the
    # summary. Like GET /v1/ward/findings, it sweeps first.
    class WardFindings < Sentinel::Native::Base
      TOOL = {
        "name" => "ward.findings",
        "description" => "The ward's findings, most severe first: { findings: [{ id, check, level, subject, message, state, " \
                         "occurrences, first_seen_at, last_seen_at, resolved_at, acknowledged_by, ack_note, ack_until }], " \
                         "count, notice }. Open ones by default. ward_status is the shorter answer to \"is anything wrong?\"; " \
                         "this is the list to work through, and where the ids ward_ack takes come from.",
        "kind" => "read",
        "realm" => "personal",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "state" => { "type" => "string", "enum" => [ *WardFinding::STATES, "all" ], "default" => "open" },
            "check" => { "type" => "string", "description" => "Only this check's findings (a slug, such as exposure)" },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => 500, "default" => 100 }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        Ward::Sweep.call
        rows = WardFinding.in_state(arguments["state"].presence || "open").by_severity.limit((arguments["limit"] || 100).to_i.clamp(1, 500))
        rows = rows.where(check_slug: arguments["check"]) if arguments["check"].present?
        findings = rows.map(&:as_json_for_ward)
        { "findings" => findings, "count" => findings.size, "notice" => Sentinel::Native::WardStatus::NOTICE }
      end
    end
  end
end
