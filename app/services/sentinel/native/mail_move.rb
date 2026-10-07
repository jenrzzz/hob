module Sentinel
  module Native
    # mail.move: file messages. Nothing here deletes: trash is a mailbox
    # like any other, and what is moved there can be moved back.
    class MailMove < MailHandler
      CAPABILITY = {
        "name" => "mail.move",
        "description" => "File messages, up to #{Email::MAX_IDS} at a time from one account. `to` moves them: out of every " \
                         "mailbox they are in and into that one (to archive, `to: \"archive\"`). `add` and `remove` label " \
                         "them instead: into or out of a mailbox, leaving the rest; a message is always in at least one. " \
                         "Returns { messages: [#{SUMMARY}] as they are now, failed: [{ id, error }], notice }. Nothing deletes " \
                         "a message: moving one to trash is moving it, and it can be moved back.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "id" => { "type" => %w[string array], "items" => { "type" => "string" },
                      "description" => "A message id from mail.search or mail.poll, or a list of them from one account" },
            "to" => MAILBOX.merge("description" => "Move here: #{MAILBOX_REF}"),
            "add" => MAILBOXES.merge("description" => "Label with this mailbox, or these: #{MAILBOX_REF}"),
            "remove" => MAILBOXES.merge("description" => "Take out of this mailbox, or these: #{MAILBOX_REF}")
          },
          "required" => %w[id],
          "additionalProperties" => false
        }
      }.freeze

      def call
        require_argument(:id)
        noticed(Email.move(arguments))
      end
    end
  end
end
