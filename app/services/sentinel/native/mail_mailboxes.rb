module Sentinel
  module Native
    # mail.mailboxes: the folders and labels visible at the agent's clearance.
    class MailMailboxes < MailHandler
      CAPABILITY = {
        "name" => "mail.mailboxes",
        "description" => "The household's mailboxes (folders and labels) visible at the agent's clearance, across every mail " \
                         "account in sight (Fastmail, by way of hob). Returns { mailboxes: [#{MAILBOX_SHAPE}], unavailable: " \
                         "[{ backend, error }], notice }. `role` marks the special ones (inbox, archive, sent, drafts, trash, " \
                         "junk); `path` is the name under its parents. A mailbox id, name, path, or role is what mail.search, " \
                         "mail.poll, and mail.move take as a mailbox.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "backend" => BACKEND },
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Email.mailboxes(arguments))
      end
    end
  end
end
