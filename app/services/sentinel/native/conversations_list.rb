module Sentinel
  module Native
    # hob.conversations.list: the conversations visible at the agent's
    # clearance (RLS decides; the handler adds nothing).
    class ConversationsList < Base
      CAPABILITY = {
        "name" => "hob.conversations.list",
        "description" => "List conversations visible at the agent's clearance: id, title, surface, realm, updated_at.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "kind" => { "type" => "string", "enum" => %w[chat pipeline all] },
            "surface" => { "type" => "string" },
            "limit" => { "type" => "integer", "maximum" => 100 }
          }
        }
      }.freeze

      def call
        kind = arguments["kind"].presence || "chat"
        scope = Conversation.order(updated_at: :desc).limit([ arguments["limit"].to_i, 100 ].min.then { |n| n.positive? ? n : 20 })
        scope = scope.where(kind: kind) unless kind == "all"
        scope = scope.where(surface: arguments["surface"]) if arguments["surface"].present?
        { "conversations" => scope.map { |c| { "id" => c.id, "kind" => c.kind, "title" => c.title, "surface" => c.surface,
                                                 "realm" => c.realm, "updated_at" => c.updated_at } } }
      end
    end
  end
end
