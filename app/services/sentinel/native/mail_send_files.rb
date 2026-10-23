module Sentinel
  module Native
    # hob.mail.send_files (petition 01M5K1P1ECDDJR13ANSE98YDM6): a new
    # message carrying up to 5 attachments the agent supplies at send time —
    # filename, MIME type, and base64 bytes, sniffed and size-capped before
    # any of it reaches the account — alongside the by-reference form
    # hob.mail.send_attachment already has. Kept apart from that capability,
    # whose grant is reference-only, and from mail.send, which carries no
    # attachments at all; this one gets its own policy row, confirmed on
    # every send like both of them (MAIL.md).
    class MailSendFiles < MailHandler
      CAPABILITY = {
        "name" => "hob.mail.send_files",
        "description" => "Send a new plain-text message from a household account with up to 5 attachments, each either " \
                         "uploaded by the agent at send time (filename, MIME type, base64 content) or copied by reference " \
                         "from existing household mail. A person confirms every send after seeing each file; the call " \
                         "returns the sent message summary. Returns { message: #{SUMMARY}, sent: true, attachments: " \
                         "[{ filename, mime_type, bytes, sha256 }] for an upload, or [{ size, filename, mime_type, " \
                         "attachment_id, source_message_id }] for a reference, notice }. A filename with a path " \
                         "separator, a declared MIME type that doesn't match the file's own bytes, malformed base64, " \
                         "or more than 10 MB across every file (decoded and referenced) is refused before anything is " \
                         "sent. If it fails as unavailable it may still have gone: look in the sent mailbox with " \
                         "mail.search before sending again.",
        "kind" => "act",
        "realm" => "personal",
        "requires_person" => true,
        "input_schema" => {
          "type" => "object",
          "required" => %w[to subject body attachments],
          "properties" => {
            "cc" => { "type" => "array", "items" => { "type" => "string", "format" => "email" } },
            "to" => { "type" => "array", "items" => { "type" => "string", "format" => "email" }, "minItems" => 1 },
            "body" => { "type" => "string", "maxLength" => 100_000 },
            "reason" => { "type" => "string" },
            "account" => { "type" => "string", "description" => "household sending account; defaults to the requesting principal's default" },
            "subject" => { "type" => "string", "maxLength" => 300 },
            "attachments" => {
              "type" => "array",
              "items" => {
                "oneOf" => [
                  {
                    "type" => "object",
                    "required" => %w[filename mime_type content_base64],
                    "properties" => {
                      "filename" => { "type" => "string", "pattern" => "^[^/\\\\]{1,128}$" },
                      "mime_type" => { "type" => "string", "enum" => Email::FILE_MIME_TYPES },
                      "content_base64" => { "type" => "string" }
                    },
                    "additionalProperties" => false
                  },
                  {
                    "type" => "object",
                    "required" => %w[message_id attachment_id],
                    "properties" => {
                      "message_id" => { "type" => "string" },
                      "attachment_id" => { "type" => "string" }
                    },
                    "additionalProperties" => false
                  }
                ]
              },
              "maxItems" => 5,
              "minItems" => 1
            }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Email.send_files(arguments))
      end
    end
  end
end
