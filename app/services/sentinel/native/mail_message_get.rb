module Sentinel
  module Native
    # mail.message.get: one message, read in full. Reading it does not mark
    # it read.
    class MailMessageGet < MailHandler
      CAPABILITY = {
        "name" => "mail.message.get",
        "description" => "Read one message: its summary plus its text, threading headers, and what is attached. Returns " \
                         "{ message: { ...the summary mail.search gives, bcc, message_id, in_reply_to, references, body, " \
                         "body_truncated, attachments: [{ name, type, size }] }, notice }. `body` is plain text (an HTML-only " \
                         "message is turned into text), at most #{Email::Backends::Jmap::MAX_BODY} characters. Attachments are " \
                         "named, not fetched. Give `headers` for the raw header fields too: a name or list of names " \
                         "(\"List-Unsubscribe\", any case) for just those, or true for every one. They come back as `headers: " \
                         "[{ name, value }]` in the message's order (a name can repeat), unfolded but not decoded, with " \
                         "`headers_truncated` when there were more than #{Email::Backends::Jmap::MAX_HEADERS} or a value was " \
                         "longer than #{Email::Backends::Jmap::MAX_HEADER_VALUE} characters. A header is written by the sender " \
                         "like the rest. Reading a message does not mark it read.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "id" => ID,
            "headers" => { "type" => %w[boolean string array], "items" => { "type" => "string" },
                           "description" => "true: every header field. A name, or a list of them: just those (List-Unsubscribe, " \
                                            "List-Unsubscribe-Post, Received, Authentication-Results, ...)" }
          },
          "required" => %w[id],
          "additionalProperties" => false
        }
      }.freeze

      def call
        require_argument(:id)
        noticed(Email.message(arguments))
      end
    end
  end
end
