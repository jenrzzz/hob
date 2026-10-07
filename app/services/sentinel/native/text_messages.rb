module Sentinel
  module Native
    # text.messages: messages by chat, sender, words, or time, newest first.
    class TextMessages < TextHandler
      CAPABILITY = {
        "name" => "text.messages",
        "description" => "Read the household's text messages visible at the agent's clearance, newest first: one chat's " \
                         "conversation (`chat` from text.chats), or a search across them all. Every filter given must match. " \
                         "#{Texts::DEFAULT_LIMIT} by default and at most #{Texts::MAX_LIMIT}; `truncated` means there were more: page " \
                         "back with `before` set to the last message's sent_at. A `q` search reads a bounded number of messages; " \
                         "when it stopped early, `searched_back_to` is how far back it got (narrow with chat or after to reach " \
                         "further). Tapbacks are folded into `reactions` on the message they were left on. Returns { messages: " \
                         "[#{MESSAGE_SHAPE}], count, truncated, searched_back_to, unavailable, notice }. Times carry the household's offset.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "backend" => BACKEND,
            "chat" => CHAT.merge("description" => "Only this chat: #{CHAT['description']}"),
            "from" => { "type" => "string", "description" => "The sender's number, address, or contact name, in part; \"me\" for the household's own" },
            "q" => { "type" => "string", "description" => "Words that must all appear in the text" },
            "after" => { "type" => "string", "description" => "Sent at or after: #{TIME}" },
            "before" => { "type" => "string", "description" => "Sent before: #{TIME}" },
            "unread" => { "type" => "boolean", "description" => "true: only incoming messages not yet read; false: the rest" },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => Texts::MAX_LIMIT, "default" => Texts::DEFAULT_LIMIT }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        result = Texts.messages(arguments)
        noticed(result.merge("count" => result["messages"].size))
      end
    end
  end
end
