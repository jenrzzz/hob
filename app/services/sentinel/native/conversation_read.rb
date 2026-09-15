module Sentinel
  module Native
    # hob.conversation.read: one branch's transcript, if the agent can see it.
    class ConversationRead < Base
      CAPABILITY = {
        "name" => "hob.conversation.read",
        "description" => "Read a conversation's messages on a branch (default main).",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "id" => { "type" => "string" }, "branch" => { "type" => "string" } },
          "required" => %w[id]
        }
      }.freeze

      def call
        conversation = Conversation.find_by(id: require_argument(:id))
        raise Error, "no conversation #{arguments['id']}" if conversation.nil?

        branch = conversation.branches.find_by(name: arguments["branch"].presence || Conversation::MAIN)
        raise Error, "no branch #{arguments['branch']}" if branch.nil?

        { "id" => conversation.id, "title" => conversation.title, "realm" => conversation.realm, "branch" => branch.name,
          "messages" => branch.timeline.map { |n| node_json(n) } }
      end
    end
  end
end
