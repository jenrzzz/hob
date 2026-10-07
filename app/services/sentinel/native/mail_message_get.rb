module Sentinel
  module Native
    # mail.message.get: one message, read in full. Reading it does not mark
    # it read.
    class MailMessageGet < MailHandler
      CAPABILITY = {
        "name" => "mail.message.get",
        "description" => "Read one message: its summary plus its text, headers, and what is attached. Returns { message: " \
                         "{ ...the summary mail.search gives, bcc, message_id, in_reply_to, references, body, body_truncated, " \
                         "attachments: [{ name, type, size }] }, notice }. `body` is plain text (an HTML-only message is turned " \
                         "into text), at most #{Email::Backends::Jmap::MAX_BODY} characters. Attachments are named, not " \
                         "fetched. Reading a message does not mark it read.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "id" => ID },
          "required" => %w[id],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Email.message(require_argument(:id)))
      end
    end
  end
end
