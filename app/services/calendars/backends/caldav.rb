require "nokogiri"

module Calendars
  module Backends
    # A CalDAV account (RFC 4791): every calendar under one calendar home,
    # reached with a username and a password. `url` is the calendar home;
    # Fastmail (the subclass) knows its own. Reads only: PROPFIND for the
    # calendars, a calendar-query REPORT per calendar for the events in a
    # window. The server sends whole events (a series and its exceptions)
    # and Calendars::Ical expands them here, so every server is expanded the
    # same way whatever it supports.
    #
    # `calendars` in the config confines a row to the calendars it names (by
    # name or id): the rest of the account does not exist for it. That is
    # how one account is shared at two realms, a `household` row naming the
    # family calendar and a `personal` row naming none. It is hob's lock
    # alone: an app password reaches every calendar on the account.
    class Caldav < Base
      CONFIG_KEYS = (%w[url username key key_env calendars] + SHARED_CONFIG).freeze
      NS = { "d" => "DAV:", "c" => "urn:ietf:params:xml:ns:caldav", "a" => "http://apple.com/ns/ical/" }.freeze
      WRITE_PRIVILEGES = %w[all write write-content].freeze

      PROPFIND = <<~XML.freeze
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav" xmlns:a="http://apple.com/ns/ical/">
          <d:prop>
            <d:resourcetype/>
            <d:displayname/>
            <a:calendar-color/>
            <c:supported-calendar-component-set/>
            <c:calendar-timezone/>
            <d:current-user-privilege-set/>
          </d:prop>
        </d:propfind>
      XML

      def self.config_errors(config)
        errors = unknown_errors(config, CONFIG_KEYS)
        errors += url_errors(config)
        errors << "needs a username: the account's login" if config["username"].blank?
        errors += secret_errors(config, "key", "the account's (app) password", "FASTMAIL_APP_PASSWORD")
        if config.key?("calendars") && !(config["calendars"].is_a?(Array) && config["calendars"].all? { |c| c.is_a?(String) && c.present? })
          errors << "calendars is a list of calendar names or ids"
        end
        errors + super
      end

      def self.url_errors(config)
        config["url"].to_s.match?(%r{\Ahttps?://\S+\z}) ? [] : [ "needs a url (http or https): the account's calendar home" ]
      end

      def calendars
        collections.map { |collection| calendar(collection) }
      end

      def events(from, to, calendars)
        chosen = collections
        chosen = chosen.select { |collection| calendars.include?(collection[:native]) } if calendars
        chosen.flat_map do |collection|
          resources(collection, from, to).flat_map do |text|
            Calendars::Ical.events(text, from: from, to: to, zone: collection[:zone] || zone,
                                         calendar: calendar(collection).slice("id", "name"), id_prefix: prefixed(collection[:native]))
          end
        end
      end

      def check
        found = collections
        { "reachable" => true, "home" => home, "calendars" => found.map { |collection| collection[:name] } }
      end

      private

      def home
        url = backend.config["url"].to_s
        url.end_with?("/") ? url : "#{url}/"
      end

      def calendar(collection)
        { "id" => prefixed(collection[:native]), "backend" => backend.name, "name" => collection[:name],
          "color" => collection[:color], "read_only" => collection[:read_only], "time_zone" => (collection[:zone] || zone).tzinfo.name }
      end

      # The event calendars under the home that this row may reach, as
      # { native:, url:, name:, color:, read_only:, zone: }.
      def collections
        @collections ||= begin
          document = dav("PROPFIND", home, PROPFIND, depth: "1")
          found = document.xpath("//d:response", NS).filter_map { |response| collection(response) }
          allowed = backend.config["calendars"]
          allowed ? found.select { |c| allowed.any? { |name| name == c[:native] || name.casecmp?(c[:name]) } } : found
        end
      end

      def collection(response)
        href = response.at_xpath("d:href", NS)&.text.to_s
        prop = response.xpath("d:propstat[contains(d:status, ' 200 ')]/d:prop", NS)
        return nil unless prop.at_xpath("d:resourcetype/c:calendar", NS)

        components = prop.xpath("c:supported-calendar-component-set/c:comp/@name", NS).map(&:value)
        return nil if components.any? && !components.include?("VEVENT")

        native = URI.decode_www_form_component(href.split("/").reject(&:empty?).last.to_s)
        privileges = prop.xpath("d:current-user-privilege-set/d:privilege/*", NS).map(&:name)
        tzid = prop.at_xpath("c:calendar-timezone", NS)&.text.to_s[/^TZID:(.+?)\r?$/, 1]
        { native: native, url: URI.join(home, href).to_s, name: prop.at_xpath("d:displayname", NS)&.text.presence || native,
          color: prop.at_xpath("a:calendar-color", NS)&.text.presence&.slice(0, 7),
          read_only: privileges.any? && (privileges & WRITE_PRIVILEGES).empty?,
          zone: tzid && ActiveSupport::TimeZone[tzid.strip] }
      end

      # The iCalendar text of every event in a calendar that touches from...to.
      def resources(collection, from, to)
        query = <<~XML
          <?xml version="1.0" encoding="utf-8"?>
          <c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
            <d:prop><d:getetag/><c:calendar-data/></d:prop>
            <c:filter>
              <c:comp-filter name="VCALENDAR">
                <c:comp-filter name="VEVENT">
                  <c:time-range start="#{stamp(from)}" end="#{stamp(to)}"/>
                </c:comp-filter>
              </c:comp-filter>
            </c:filter>
          </c:calendar-query>
        XML
        dav("REPORT", collection[:url], query, depth: "1").xpath("//c:calendar-data", NS).map(&:text).select(&:present?)
      end

      def stamp(time)
        time.utc.strftime("%Y%m%dT%H%M%SZ")
      end

      # -> the multistatus document.
      def dav(verb, url, body, depth:)
        key = backend.key
        raise Calendars::Unavailable, "#{backend.name} has no password: #{key_hint}" if key.blank?

        headers = { "Authorization" => "Basic #{Base64.strict_encode64("#{backend.config['username']}:#{key}")}",
                    "Content-Type" => "application/xml; charset=utf-8", "Depth" => depth, "Accept" => "application/xml" }
        status, response = deliver(verb, url, body: body, headers: headers)
        raise status_error(status, "#{backend.name}'s CalDAV server") unless status.between?(200, 299)

        Nokogiri::XML(response.dup.force_encoding(Encoding::UTF_8))
      end

      def key_hint
        backend.config["key_env"].present? ? "#{backend.config['key_env']} is not set in hob's environment" : "set config.key or config.key_env"
      end
    end
  end
end
