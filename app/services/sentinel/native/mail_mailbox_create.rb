module Sentinel
  module Native
    # mail.mailbox.create: a new folder or label.
    class MailMailboxCreate < MailHandler
      CAPABILITY = {
        "name" => "mail.mailbox.create",
        "description" => "Make a new mailbox (a folder, or a label: in Fastmail they are the same thing), optionally under " \
                         "another. Look at mail.mailboxes first: one with that name may already be there. Returns { mailbox: " \
                         "#{MAILBOX_SHAPE}, notice }. There is no deleting one.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "name" => { "type" => "string", "maxLength" => Email::MAX_NAME, "description" => "What to call it" },
            "parent" => MAILBOX.merge("description" => "Put it under this one: #{MAILBOX_REF}"),
            "backend" => { "type" => "string", "description" => "Which account; needed only when more than one is visible and no parent names it" }
          },
          "required" => %w[name],
          "additionalProperties" => false
        }
      }.freeze

      def call
        require_argument(:name)
        noticed(Email.create_mailbox(arguments))
      end
    end
  end
end
