module Sentinel
  module Native
    # mail.send: a new message, from a person's own account. A person always
    # confirms it: it goes out under their name, to anyone, and cannot be
    # taken back, and an agent that reads mail can be talked into anything
    # by whoever wrote it.
    class MailSend < MailHandler
      CAPABILITY = {
        "name" => "mail.send",
        "description" => "Send a new message from a household account, as plain text. A person always confirms it before it " \
                         "goes: say in your reason who it is for and why. It goes out under their name and cannot be unsent. " \
                         "`to`, `subject`, and `body` are required; at most #{Email::MAX_RECIPIENTS} recipients in all. To answer " \
                         "a message, use mail.reply, which keeps the conversation together. Returns { message: #{SUMMARY}, " \
                         "sent: true, notice }. If it fails as unavailable it may still have gone: look in the sent mailbox " \
                         "with mail.search before sending again.",
        "kind" => "act",
        "realm" => "household",
        "requires_person" => true,
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "to" => ADDRESSES,
            "cc" => ADDRESSES,
            "bcc" => ADDRESSES,
            "subject" => { "type" => "string", "maxLength" => Email::MAX_SUBJECT },
            "body" => BODY.merge("maxLength" => Email::MAX_BODY),
            "from" => FROM,
            "backend" => { "type" => "string", "description" => "Which account; needed only when more than one is visible" }
          },
          "required" => %w[to subject body],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Email.send_message(arguments))
      end
    end
  end
end
