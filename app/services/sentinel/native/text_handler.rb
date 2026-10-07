module Sentinel
  module Native
    # What the text.* handlers share (TEXTS.md). They are thin: Texts does the
    # work, at the agent's clearance, so the accounts an agent can reach are
    # the ones RLS shows it and the handlers add no realm logic of their own.
    # Everything handed back carries Texts::NOTICE, since anyone with a phone
    # number can write a text. What Texts raises (NotFound, Invalid,
    # Forbidden, Unavailable) fails the request with its message.
    class TextHandler < Base
      BACKEND = { "type" => "string", "description" => "Only this backend (a name from a chat's `backend`)" }.freeze
      CHAT = { "type" => "string", "description" => "A chat id as text.chats returns it: \"<backend>:<id>\"" }.freeze
      TIME = "A date (2026-10-06: midnight where the household is) or a time with its offset (2026-10-06T15:00:00-07:00)".freeze
      PERSON = "{ handle, name }".freeze
      CHAT_SHAPE = "{ id, backend, identifier, service, group, name, display_name, participants: [#{PERSON}], last_message_at, " \
                   "unread }".freeze
      MESSAGE_SHAPE = "{ id, backend, chat_id, from_me, sender: #{PERSON} | null, text, sent_at, read_at, delivered_at, read, " \
                      "service, reply_to, edited, unsent, attachments: [{ name, type, size }], reactions: [{ reaction, emoji, " \
                      "from_me, from }] }".freeze

      private

      def noticed(result)
        result.merge("notice" => Texts::NOTICE)
      end
    end
  end
end
