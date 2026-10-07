module Sentinel
  module Native
    # text.chats: the conversations visible at the agent's clearance.
    class TextChats < TextHandler
      CAPABILITY = {
        "name" => "text.chats",
        "description" => "The household's text conversations (iMessage, SMS, and RCS, from the Messages app by way of hob) " \
                         "visible at the agent's clearance, the most recently active first. Find a chat by a person's name or " \
                         "number, or a group's name, with `q`. Returns { chats: [#{CHAT_SHAPE}], unavailable: [{ backend, error }], " \
                         "notice }. A chat's id is what text.messages, text.poll, and text.send take as `chat`. `unread` counts " \
                         "incoming messages not yet read.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "backend" => BACKEND,
            "q" => { "type" => "string", "description" => "Words that must all appear in the chat's name, or a participant's name or number" },
            "active_after" => { "type" => "string", "description" => "Only chats with a message at or after: #{TIME}" },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => Texts::MAX_LIMIT, "default" => Texts::DEFAULT_LIMIT }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        result = Texts.chats(arguments)
        noticed(result.merge("count" => result["chats"].size))
      end
    end
  end
end
