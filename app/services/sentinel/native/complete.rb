module Sentinel
  module Native
    # hob.complete: a one-shot completion through a model role, exactly what
    # POST /v1/completions does, run as the agent. Which roles an agent may
    # use is a policy constraint ({ "role": ["cheap-classifier"] }).
    class Complete < Base
      CAPABILITY = {
        "name" => "hob.complete",
        "description" => "Run a one-shot completion through one of hob's model roles, optionally with a persona " \
                         "and a JSON schema for the reply. Costs money; the ledger charges it to the agent.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "role" => { "type" => "string", "description" => "model role, e.g. cheap-classifier" },
            "messages" => { "type" => "array", "items" => { "type" => "object",
                                                            "properties" => { "role" => { "type" => "string" }, "content" => { "type" => "string" } },
                                                            "required" => %w[role content] } },
            "system" => { "type" => "string" },
            "persona" => { "type" => "string", "description" => "a persona key supplying the system prompt" },
            "schema" => { "type" => "object" },
            "operation" => { "type" => "string" }
          },
          "required" => %w[role messages]
        }
      }.freeze

      def call
        persona = arguments["persona"].presence && Persona.find_by(key: arguments["persona"])
        raise Error, "unknown persona #{arguments['persona'].inspect}" if arguments["persona"].present? && persona.nil?

        completion = Completion.new(
          role: require_argument(:role), messages: require_argument(:messages), system: arguments["system"].presence,
          persona: persona, schema: arguments["schema"].presence,
          operation: arguments["operation"].presence || "sentinel.complete",
          metadata: { "sentinel_request" => request.id }, ref: request.ref, realm: request.realm
        ).call
        response = completion.response
        {
          "id" => completion.conversation.id, "status" => completion.status,
          "content" => response.refused? ? nil : response.content, "parsed" => response.parsed,
          "usage" => response.units.merge("cost" => response.cost&.to_f), "model" => response.model
        }
      end
    end
  end
end
