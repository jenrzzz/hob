module Sentinel
  module Native
    # What the mail.* handlers share (MAIL.md). They are thin: Email does the
    # work, at the agent's clearance, so the accounts an agent can reach are
    # the ones RLS shows it and the handlers add no realm logic of their own.
    # Everything handed back carries Email::NOTICE, since anyone with an
    # address can write a message. What Email raises (NotFound, Invalid,
    # Forbidden, Unavailable) fails the request with its message.
    class MailHandler < Base
      BACKEND = { "type" => "string", "description" => "Only this backend (a name from mail.mailboxes)" }.freeze
      ID = { "type" => "string", "description" => "A message id as mail.search or mail.poll returns it: \"<backend>:<id>\"" }.freeze
      MAILBOX_REF = "A mailbox id from mail.mailboxes, or within one account its name, path (\"Receipts/2026\"), or role " \
                    "(inbox, archive, sent, drafts, trash, junk)".freeze
      MAILBOX = { "type" => "string", "description" => MAILBOX_REF }.freeze
      MAILBOXES = { "type" => %w[string array], "items" => { "type" => "string" }, "description" => "#{MAILBOX_REF}; or a list" }.freeze
      ADDRESSES = { "type" => %w[string array], "items" => { "type" => "string" },
                    "description" => "Addresses: \"ana@example.com\" or \"Ana Ruiz <ana@example.com>\"; a list, or one string separated by commas" }.freeze
      FROM = { "type" => "string", "description" => "Which of the account's addresses to send as. Default: its main one (for a reply, " \
                                                    "the address the message was sent to, when that is one of ours)" }.freeze
      BODY = { "type" => "string", "description" => "The message, as plain text" }.freeze
      ADDRESS = "{ name, email }".freeze
      MAILBOX_SHAPE = "{ id, backend, name, path, role, parent, total, unread, may_add }".freeze
      SUMMARY = "{ id, backend, thread_id, mailboxes: [{ id, name, role }], from: [#{ADDRESS}], to, cc, reply_to, subject, preview, " \
                "received_at, sent_at, unread, flagged, answered, draft, has_attachment, size }".freeze

      private

      def noticed(result)
        result.merge("notice" => Email::NOTICE)
      end
    end
  end
end
