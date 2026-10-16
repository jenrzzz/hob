module Sentinel
  module Native
    # hob.mail.download: one attachment's raw bytes, base64-encoded, so an
    # agent can hand a real file to something outside hob (an upload step),
    # not only its extracted text. Kept apart from mail.attachment.get,
    # whose grant is text-only: widening that one would quietly hand out
    # file bytes. Fetches exactly one attachment per call — no wildcards,
    # no "every attachment on a message" — and never sends, forwards,
    # uploads, or writes a byte to disk or to hob's own records.
    #
    # Reuses mail.message.get's clearance and visibility exactly (Email,
    # same as AttachmentGet): a message the agent cannot see is not_found,
    # indistinguishable from one that does not exist. The sentinel request
    # row is the audit entry hob keeps — principal and reason are on it
    # already, message_id and attachment_id are its arguments, and
    # filename, size, and sha256 are in its result — so nothing further is
    # stored, and nothing is cached beyond that row.
    class MailDownload < MailHandler
      MAX_BYTES = 10_485_760 # hard ceiling, 10 MB
      KNOWN_ARGUMENTS = %w[message_id attachment_id max_bytes reason].freeze
      NOTICE = "Attachment bytes from private mail: send them only where the household asked.".freeze

      CAPABILITY = {
        "name" => "hob.mail.download",
        "description" => "Return one email attachment's raw bytes, base64-encoded, with its filename, MIME type and " \
                         "size, so an agent can hand a real file (for example a PDF) to an upload step. It returns at " \
                         "most a capped size and nothing else from the message.",
        "kind" => "read",
        "realm" => "personal",
        "input_schema" => {
          "type" => "object",
          "required" => %w[message_id attachment_id reason],
          "properties" => {
            "message_id" => { "type" => "string", "description" => "id from mail.search, mail.poll or mail.message.get" },
            "attachment_id" => { "type" => "string",
                                 "description" => "blob/part id of the attachment as listed by mail.message.get or mail.attachment.get" },
            "max_bytes" => { "type" => "integer", "default" => MAX_BYTES, "maximum" => MAX_BYTES, "minimum" => 1 },
            "reason" => { "type" => "string", "description" => "what the file is, who asked for it, and where it will go" }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        known!
        message_id = require_argument(:message_id)
        attachment_id = require_argument(:attachment_id)
        require_argument(:reason)
        max_bytes = max_bytes!

        # Email.attachment does exactly steps 1-3 of the spec: a message
        # invisible at this clearance or gone raises Email::NotFound (the
        # same either way — not_found leaks nothing about which); no such
        # part on the message, or a declared size over max_bytes, raises
        # Email::Invalid, size and all, before a byte is fetched.
        blob = Email.attachment("id" => message_id, "attachment" => attachment_id, "max_bytes" => max_bytes)
        bytes = blob["bytes"].to_s
        {
          "message_id" => message_id, "attachment_id" => attachment_id, "filename" => blob["name"],
          "mime_type" => blob["type"], "size" => bytes.bytesize, "sha256" => Digest::SHA256.hexdigest(bytes),
          "content_base64" => Base64.strict_encode64(bytes), "notice" => NOTICE
        }
      end

      private

      def known!
        unknown = arguments.keys - KNOWN_ARGUMENTS
        raise Error, "unknown argument#{'s' if unknown.size > 1} #{unknown.join(', ')} (known: #{KNOWN_ARGUMENTS.join(', ')})" if unknown.any?
      end

      # The agent's own cap, never above the hard ceiling: both halves of
      # "declared or actual size exceeds max_bytes (hard ceiling 10 MB)"
      # collapse into one bound to check against.
      def max_bytes!
        value = arguments["max_bytes"]
        return MAX_BYTES if value.blank?
        raise Error, "max_bytes must be a positive integer" unless value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)

        value.to_i.clamp(1, MAX_BYTES)
      end
    end
  end
end
