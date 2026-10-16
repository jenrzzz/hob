module Sentinel
  module Native
    # hob.mail.send_attachment (petition 01M51PFF6736AC9F0HGQ453H5R): a send
    # or reply carrying files already in household mail, referenced by
    # message id and attachment id so their bytes travel straight from one
    # JMAP account to the sent message, never through hob or the agent, and
    # never back to the agent either. Kept apart from mail.send and
    # mail.reply, which stay plain text and untouched; this one gets its
    # own policy row, confirmed like them (MAIL.md).
    class MailSendAttachment < MailHandler
      CAPABILITY = {
        "name" => "hob.mail.send_attachment",
        "description" => "Send a new message, or a reply in an existing conversation, from a household account. It " \
                         "carries up to 5 attachments copied from messages already in household mail, referenced by " \
                         "message id and attachment id. A person confirms each send. Returns the sent message summary " \
                         "and the attachments that went with it.",
        "kind" => "act",
        "realm" => "personal",
        "requires_person" => true,
        "input_schema" => {
          "type" => "object",
          "required" => %w[body attachments],
          "properties" => {
            "cc" => { "type" => "array", "items" => { "type" => "string", "format" => "email" }, "maxItems" => 20 },
            "to" => { "type" => "array", "items" => { "type" => "string", "format" => "email" }, "maxItems" => 20 },
            "body" => { "type" => "string", "maxLength" => 20_000 },
            "quote" => { "type" => "boolean", "default" => true },
            "reason" => { "type" => "string", "maxLength" => 1000 },
            "subject" => { "type" => "string", "maxLength" => 300 },
            "reply_all" => { "type" => "boolean", "default" => false },
            "attachments" => {
              "type" => "array",
              "items" => {
                "type" => "object",
                "required" => %w[message_id attachment_id],
                "properties" => {
                  "filename" => { "type" => "string", "maxLength" => 200, "description" => "Optional rename; the original mime type is kept." },
                  "message_id" => { "type" => "string" },
                  "attachment_id" => { "type" => "string" }
                },
                "additionalProperties" => false
              },
              "maxItems" => 5,
              "minItems" => 1
            },
            "from_account" => { "type" => "string", "description" => "Household mail backend to send from; defaults as mail.send does." },
            "reply_to_message_id" => { "type" => "string",
                                       "description" => "If set, send as a reply in that message's conversation (Re: subject, " \
                                                        "quoted original unless quote is false); to and subject are then optional." }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Email.send_attachment(arguments))
      end
    end
  end
end
