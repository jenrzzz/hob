module Calendars
  module Backends
    # A calendar published as an .ics file: a subscription. Google, Fastmail,
    # iCloud, Outlook, TripIt, a school's sports schedule: anything that
    # offers "subscribe to this calendar" offers one of these. One feed is
    # one calendar, read whole on every call (a feed has no way to be asked
    # for a week) and expanded for the window asked about.
    #
    # A private feed's URL carries its own password, so it is kept like one:
    # in an env var (`url_env`) or in the row, and shown as its host alone.
    # `webcal://` is https by another name.
    class Ics < Base
      CONFIG_KEYS = (%w[url url_env name] + SHARED_CONFIG).freeze
      SCHEMES = %w[http https webcal].freeze
      NATIVE = "feed".freeze # the one calendar's native id

      def self.config_errors(config)
        errors = unknown_errors(config, CONFIG_KEYS) + secret_errors(config, "url", "the feed's address", "FAMILY_ICS_URL") + super
        if config["url"].present? && !SCHEMES.include?(URI(config["url"].to_s).scheme.to_s.downcase)
          errors << "url must be an http, https, or webcal address"
        end
        errors
      rescue URI::InvalidURIError
        errors << "url is not a URL"
      end

      def calendars
        [ calendar(fetch) ]
      end

      def events(from, to, calendars)
        return [] if calendars && !calendars.include?(NATIVE)

        text = fetch
        Calendars::Ical.events(text, from: from, to: to, zone: zone, calendar: calendar(text).slice("id", "name"),
                                     id_prefix: prefixed(NATIVE))
      end

      def check
        text = fetch
        { "reachable" => true, "calendar" => calendar(text)["name"], "events" => Calendars::Ical.parse(text).sum { |c| c.events.size },
          "bytes" => text.bytesize }
      end

      private

      def calendar(text)
        { "id" => prefixed(NATIVE), "backend" => backend.name,
          "name" => backend.config["name"].presence || Calendars::Ical.name_of(text) || backend.name,
          "color" => nil, "read_only" => true, "time_zone" => zone.tzinfo.name }
      end

      def fetch
        url = backend.secret("url")
        raise Calendars::Unavailable, "#{backend.name} has no feed URL: #{url_hint}" if url.blank?

        status, body = deliver("GET", url.sub(/\Awebcal:/i, "https:"), headers: { "Accept" => "text/calendar, */*;q=0.5" })
        raise status_error(status, "#{backend.name}'s feed") unless status.between?(200, 299)

        body = body.dup.force_encoding(Encoding::UTF_8).scrub.delete_prefix("\uFEFF")
        raise Calendars::Unavailable, "#{backend.name}'s feed is not an iCalendar document" unless body.lstrip.start_with?("BEGIN:VCALENDAR")

        body
      end

      def url_hint
        backend.config["url_env"].present? ? "#{backend.config['url_env']} is not set in hob's environment" : "set config.url or config.url_env"
      end
    end
  end
end
