module Sentinel
  module Native
    # hob.usage: the ledger summary. Defaults to the agent's own spend; a
    # policy constraint decides whether it may ask for the whole household.
    class Usage < Base
      CAPABILITY = {
        "name" => "hob.usage",
        "description" => "Summarize hob's usage ledger: calls, tokens, and cost, by role and operation. " \
                         "Defaults to the agent's own surface; surface \"all\" is the whole household.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "since" => { "type" => "string", "description" => "ISO8601" },
            "surface" => { "type" => "string" },
            "ref" => { "type" => "string" },
            "role" => { "type" => "string" },
            "operation" => { "type" => "string" }
          }
        }
      }.freeze

      def call
        scope = UsageEvent.all
        surface = arguments["surface"].presence || request.surface
        scope = scope.where(surface: surface) unless surface == "all"
        scope = scope.where(ref: arguments["ref"]) if arguments["ref"].present?
        scope = scope.where(role: arguments["role"]) if arguments["role"].present?
        scope = scope.where(operation: arguments["operation"]) if arguments["operation"].present?
        scope = scope.since(Time.zone.parse(arguments["since"])) if arguments["since"].present?
        rows = scope.order(created_at: :desc).limit(10_000).to_a
        UsageEvent.summarize(rows).merge(
          "by_role" => rows.group_by(&:role).transform_values { |r| UsageEvent.summarize(r).slice(:calls, :cost) },
          "by_operation" => rows.group_by(&:operation).transform_values { |r| UsageEvent.summarize(r).slice(:calls, :cost) }
        ).deep_stringify_keys
      end
    end
  end
end
