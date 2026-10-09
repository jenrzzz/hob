module Sentinel
  module Native
    # mail.poll: what arrived since the agent last looked. hob keeps no
    # place for it: the cursor is the agent's to keep.
    class MailPoll < MailHandler
      CAPABILITY = {
        "name" => "mail.poll",
        "description" => "New mail since you last looked: messages that arrived after `cursor`, oldest first, optionally only " \
                         "those matching a filter. Call it once without a cursor to get one (and no messages), then keep the " \
                         "cursor each answer returns and give it next time; hob does not remember it for you. New means " \
                         "delivered to the account: not drafts, not what was sent from it, not trash or junk, and not a message " \
                         "merely moved. `more: true` means ask again now. An account in `reset` lost its place: anything that " \
                         "arrived there since your last look is for mail.search (after:) to find. `reset_details` says why, " \
                         "one entry per reset account with its `type` and `description`. Filters match in part: " \
                         "`from` the sender's name or address, `to` a recipient's, `subject` the subject, and `q`'s words the " \
                         "subject, preview, or addresses. Returns { cursor, messages: [#{SUMMARY}], count, more, reset, " \
                         "reset_details, unavailable, notice }. Pair it with hob.schedule.create to look on a clock.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "cursor" => { "type" => "string", "description" => "What the last mail.poll returned as `cursor`. Leave it out the first time" },
            "backend" => BACKEND,
            "mailbox" => MAILBOX.merge("description" => "Only what arrived in this mailbox: #{MAILBOX_REF}"),
            "q" => { "type" => "string", "description" => "Words that must all appear in the subject, preview, or addresses" },
            "from" => { "type" => "string", "description" => "In the sender's name or address" },
            "to" => { "type" => "string", "description" => "In a recipient's name or address (to or cc)" },
            "subject" => { "type" => "string", "description" => "In the subject" },
            "unread" => { "type" => "boolean", "description" => "true: only those still unread" },
            "has_attachment" => { "type" => "boolean" }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Email.poll(arguments))
      end
    end
  end
end
