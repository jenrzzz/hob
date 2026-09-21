module Mcp
  module Tools
    # ward.unack (WARD.md): take an acknowledgement back; the finding is open again.
    class WardUnack < Sentinel::Native::Base
      TOOL = {
        "name" => "ward.unack",
        "description" => "Withdraw the acknowledgement on a ward finding, so it counts as open again. Returns { finding }.",
        "kind" => "act",
        "realm" => "personal",
        "input_schema" => {
          "type" => "object",
          "properties" => { "id" => { "type" => "string", "description" => "A finding id from ward_findings or ward_status" } },
          "required" => %w[id],
          "additionalProperties" => false
        }
      }.freeze

      def call
        finding = WardFinding.find(require_argument(:id))
        finding.unacknowledge!
        { "finding" => finding.as_json_for_ward }
      end
    end
  end
end
