module Sentinel
  module Native
    # text.send: a text from a person's own phone number. A person always
    # confirms it: it goes out under their name, to anyone, and cannot be
    # taken back, and an agent that reads texts can be talked into anything
    # by whoever wrote one.
    class TextSend < TextHandler
      CAPABILITY = {
        "name" => "text.send",
        "description" => "Send a text from a household account: into an existing `chat` (from text.chats; a group too), or `to` " \
                         "one person's phone number or address. A person always confirms it before it goes: say in your reason " \
                         "who it is for and why. It goes out under their name and cannot be unsent. Returns { status: \"sent\", " \
                         "message: #{MESSAGE_SHAPE}, chat_id, notice } once Messages has it, or { status: \"pending\", chat_id, " \
                         "notice } when Messages took it but it had not shown up yet: it is usually on its way, so look with " \
                         "text.messages (chat, from: \"me\") before sending again. The same goes for a send that fails as unavailable.",
        "kind" => "act",
        "realm" => "household",
        "requires_person" => true,
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "chat" => CHAT.merge("description" => "The chat to send into: #{CHAT['description']}. Give chat or to, not both"),
            "to" => { "type" => "string", "description" => "A phone number (+15551234567) or address, for a one-to-one text" },
            "text" => { "type" => "string", "maxLength" => Texts::MAX_TEXT, "description" => "What the message says, as plain text" },
            "backend" => { "type" => "string", "description" => "Which account; needed with `to` only when more than one is visible" }
          },
          "required" => %w[text],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Texts.send_message(arguments))
      end
    end
  end
end
