module Sentinel
  module Native
    # mail.reply: an answer to a message, in its conversation. A person
    # always confirms it, for the reasons mail.send gives.
    class MailReply < MailHandler
      CAPABILITY = {
        "name" => "mail.reply",
        "description" => "Reply to a message, as plain text, in its conversation: to its sender (or their Reply-To), with " \
                         "\"Re:\" on the subject and the original quoted beneath unless `quote: false`. `reply_all: true` copies " \
                         "everyone else it went to. A person always confirms it before it goes: say in your reason what you are " \
                         "answering and why. Returns { message: #{SUMMARY}, sent: true, in_reply_to, notice }, and the original " \
                         "is marked answered. If it fails as unavailable it may still have gone: look in the sent mailbox with " \
                         "mail.search before replying again.",
        "kind" => "act",
        "realm" => "household",
        "requires_person" => true,
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "id" => ID.merge("description" => "The message to answer: an id from mail.search or mail.poll"),
            "body" => BODY.merge("maxLength" => Email::MAX_BODY, "description" => "Your reply, as plain text, without the quote"),
            "reply_all" => { "type" => "boolean", "default" => false, "description" => "true: copy everyone the message went to" },
            "quote" => { "type" => "boolean", "default" => true, "description" => "false: leave the original out" },
            "cc" => ADDRESSES.merge("description" => "Anyone else to copy: #{ADDRESSES['description']}"),
            "bcc" => ADDRESSES,
            "from" => FROM
          },
          "required" => %w[id body],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Email.reply(arguments))
      end
    end
  end
end
