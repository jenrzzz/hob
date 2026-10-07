module Sentinel
  module Native
    # mail.search: messages by what is in them, newest first. Which accounts
    # that reaches is RLS's answer; the handler adds nothing.
    class MailSearch < MailHandler
      TIME = "A date (2026-10-06: midnight where the household is) or a time with its offset (2026-10-06T15:00:00-07:00)".freeze

      CAPABILITY = {
        "name" => "mail.search",
        "description" => "Search the household's mail visible at the agent's clearance: the inbox, the archive, and every " \
                         "other mailbox but trash and junk unless `mailbox` names one. Every filter given must match. Newest " \
                         "first, #{Email::DEFAULT_LIMIT} by default and at most #{Email::MAX_LIMIT}; page back with `before` " \
                         "set to the last message's received_at. Returns { messages: [#{SUMMARY}], total, truncated, " \
                         "unavailable: [{ backend, error }], notice }. A summary has a `preview`, not the body: mail.message.get " \
                         "reads one. Times carry the household's offset.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "backend" => BACKEND,
            "mailbox" => MAILBOX.merge("description" => "Only this mailbox: #{MAILBOX_REF}"),
            "q" => { "type" => "string", "description" => "Words anywhere in the message: addresses, subject, body" },
            "from" => { "type" => "string", "description" => "In the sender's name or address" },
            "to" => { "type" => "string", "description" => "In a recipient's name or address (to or cc)" },
            "subject" => { "type" => "string", "description" => "In the subject" },
            "after" => { "type" => "string", "description" => "Received at or after: #{TIME}" },
            "before" => { "type" => "string", "description" => "Received before: #{TIME}" },
            "unread" => { "type" => "boolean", "description" => "true: only unread; false: only read" },
            "flagged" => { "type" => "boolean", "description" => "true: only flagged; false: only unflagged" },
            "has_attachment" => { "type" => "boolean" },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => Email::MAX_LIMIT, "default" => Email::DEFAULT_LIMIT }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        result = Email.search(arguments)
        noticed(result.merge("count" => result["messages"].size))
      end
    end
  end
end
