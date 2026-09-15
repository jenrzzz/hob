module Sentinel
  module Native
    # hob.conversation.event: append an event node — the agent leaving a note
    # in a timeline ("Muse booked the table"). Out of the prompt, in the log.
    class ConversationEvent < Base
      CAPABILITY = {
        "name" => "hob.conversation.event",
        "description" => "Append an event to a conversation's timeline: a side effect the agent performed, recorded out of the prompt.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "id" => { "type" => "string" }, "content" => { "type" => "string" },
                            "branch" => { "type" => "string" }, "meta" => { "type" => "object" } },
          "required" => %w[id content]
        }
      }.freeze

      def call
        conversation = Conversation.find_by(id: require_argument(:id))
        raise Error, "no conversation #{arguments['id']}" if conversation.nil?

        branch = conversation.branches.find_by(name: arguments["branch"].presence || Conversation::MAIN)
        raise Error, "no branch #{arguments['branch']}" if branch.nil?

        meta = (arguments["meta"].is_a?(Hash) ? arguments["meta"] : {}).merge("agent" => request.principal.name, "sentinel_request" => request.id)
        node = MessageNode.append!(conversation: conversation, parent_hash: branch.head_hash, role: "event", kind: "event",
                                   content: require_argument(:content), meta: meta)
        branch.advance!(node)
        node_json(node).deep_stringify_keys
      end
    end
  end
end
