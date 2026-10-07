module Email
  module Backends
    # Fastmail's mail, over JMAP: the same as any JMAP account, with the
    # session resource known (https://api.fastmail.com/jmap/session).
    #
    # The key is an API token (Settings → Privacy & Security → Manage API
    # tokens), never the account's password. Give it Email access to read
    # and file, and Email submission too for it to send; a token with
    # read-only Email access can search and poll and nothing else.
    class Fastmail < Jmap
      URL = "https://api.fastmail.com/jmap/session".freeze

      def self.url_errors(config)
        config["url"].blank? ? [] : super
      end

      private

      def session_url
        backend.config["url"].presence || URL
      end
    end
  end
end
