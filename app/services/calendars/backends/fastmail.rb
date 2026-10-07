module Calendars
  module Backends
    # Fastmail's calendars, over CalDAV. The same as any CalDAV account, with
    # the calendar home worked out from the username:
    # https://caldav.fastmail.com/dav/calendars/user/<username>/.
    #
    # The password is an app password (Settings → Privacy & Security → App
    # passwords) with CalDAV access, never the account's own. Fastmail's
    # JMAP API does not offer calendars to third parties, so CalDAV it is.
    class Fastmail < Caldav
      URL = "https://caldav.fastmail.com/dav/calendars/user/".freeze

      def self.url_errors(config)
        config["url"].blank? ? [] : super
      end

      private

      def home
        return super if backend.config["url"].present?

        "#{URL}#{ERB::Util.url_encode(backend.config['username'].to_s).gsub('%40', '@')}/"
      end
    end
  end
end
