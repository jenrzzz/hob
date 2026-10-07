require "icalendar"
require "rrule"

module Calendars
  # iCalendar text (RFC 5545) into the contract's events, for one window.
  # Both kinds of backend hand their calendars over this way: an .ics feed
  # is one big VCALENDAR, and a CalDAV REPORT answers with one per event.
  #
  # Every occurrence that overlaps the window comes back as an event of its
  # own: a weekly standup is one event per Monday, with the series' `uid`
  # and that Monday's `recurrence_id`. What a series says about its
  # occurrences is honoured: RRULE and RDATE make them, EXDATE takes them
  # away, and a VEVENT with a RECURRENCE-ID replaces the one it names (moved,
  # retitled, or cancelled).
  #
  # Times keep the zone they were written in (an event at 9:00 in
  # America/Los_Angeles comes back as 09:00:00-07:00 with that time_zone),
  # and a floating time, or one in a zone nobody defined, is read in `zone`.
  # An all-day event's start and end are dates, the end exclusive.
  module Ical
    DESCRIPTION_LIMIT = 1000
    TEXT_LIMIT = 500
    MAX_OCCURRENCES = 1000 # per series, per window
    # A series every few seconds or minutes is a bug in the feed, not a
    # calendar anyone keeps; its first occurrence is all that is shown.
    UNEXPANDED = %w[SECONDLY MINUTELY].freeze
    STATUSES = %w[confirmed tentative cancelled].freeze

    module_function

    # -> [event], each with "_starts" and "_ends" (Times) for the façade to
    # filter and sort by. `calendar` is { "id", "name" }; `id_prefix` is
    # what goes before an event's uid in its id.
    def events(text, from:, to:, zone:, calendar:, id_prefix:)
      parse(text).flat_map(&:events).group_by { |vevent| vevent.uid.to_s }.flat_map do |uid, vevents|
        next [] if uid.blank?

        occurrences(vevents, from, to, zone).map do |occurrence|
          event(occurrence, calendar: calendar, id_prefix: id_prefix, zone: zone)
        end
      end
    end

    # The calendars in a text, or Unavailable: whatever answered was not one.
    def parse(text)
      calendars = Icalendar::Calendar.parse(text.to_s)
      raise Calendars::Unavailable, "the answer was not an iCalendar document" if calendars.empty?

      calendars
    rescue Calendars::Error
      raise
    rescue StandardError => e
      raise Calendars::Unavailable, "the answer was not an iCalendar document (#{e.class.name.demodulize})"
    end

    # The calendar's own name for itself (X-WR-CALNAME), if it gives one.
    def name_of(text)
      Array(parse(text).first.custom_property("x_wr_calname")).first.to_s.strip.presence
    rescue Calendars::Error
      nil
    end

    Occurrence = Struct.new(:vevent, :starts, :ends, :all_day, :time_zone, :recurrence_id, :recurring, keyword_init: true)

    # One uid's VEVENTs, the series and its exceptions, as the occurrences
    # that overlap from...to.
    def occurrences(vevents, from, to, zone)
      master = vevents.find { |vevent| vevent.recurrence_id.nil? }
      overrides = vevents.select(&:recurrence_id).index_by { |vevent| key(resolve(vevent.recurrence_id, vevent, zone)) }
      list = []

      if master && (master.rrule.any? || master.rdate.any?)
        consumed = Set.new
        series(master, from, to, zone).each do |starts|
          k = key(starts)
          if (override = overrides[k])
            consumed << k
            list << single(override, zone, recurrence_id: starts, recurring: true)
          else
            list << shifted(master, starts, zone)
          end
        end
        # An exception whose original slot fell outside the window may have
        # been moved into it.
        overrides.each do |k, override|
          list << single(override, zone, recurrence_id: resolve(override.recurrence_id, override, zone), recurring: true) unless consumed.include?(k)
        end
      else
        list << single(master, zone) if master
        # Exceptions with no series in sight (a CalDAV server can send just
        # the instance that matched): each stands on its own.
        overrides.each_value { |override| list << single(override, zone, recurrence_id: resolve(override.recurrence_id, override, zone), recurring: true) }
      end

      list.compact.select { |occurrence| overlaps?(occurrence, from, to, zone) }
    end

    # The start of every occurrence of a series that could overlap from...to.
    def series(master, from, to, zone)
      starts = resolve(master.dtstart, master, zone)
      return [] if starts.nil?

      # Far enough back to catch an occurrence that began before the window
      # and is still going when it opens; RRule never goes before dtstart.
      span = length(master, starts, zone)
      window_from = from - (starts.is_a?(Date) ? span.days : span.seconds) - 1.day
      excluded = master.exdate.flatten.filter_map { |value| key(resolve(value, master, zone, ical_tzid: tzid(value))) }.to_set

      found = master.rrule.flat_map do |rule|
        rrule = rule.value_ical.to_s
        next [ starts ] if UNEXPANDED.any? { |freq| rrule.include?("FREQ=#{freq}") }

        expand(rrule, starts, window_from, to)
      end
      found += master.rdate.flatten.filter_map { |value| resolve(value, master, zone, ical_tzid: tzid(value)) }
      found = [ starts, *found ] if master.rdate.any? && master.rrule.empty?
      found.uniq { |time| key(time) }.reject { |time| excluded.include?(key(time)) }.sort_by { |time| instant(time, zone) }.first(MAX_OCCURRENCES)
    end

    # RRULE expansion, in the series' own zone so 9:00 stays 9:00 across a
    # DST change. An all-day series is expanded at UTC midnights and handed
    # back as dates; a series in a zone with no IANA name (a custom
    # VTIMEZONE) at its fixed offset.
    def expand(rrule, starts, window_from, window_to)
      if starts.is_a?(Date)
        rule = RRule::Rule.new(rrule, dtstart: Time.utc(starts.year, starts.month, starts.day), tzid: "UTC", max_year: window_to.year + 1)
        rule.between(window_from, window_to, limit: MAX_OCCURRENCES).map(&:to_date)
      else
        tz = starts.respond_to?(:time_zone) ? starts.time_zone.tzinfo.name : "UTC"
        dtstart = starts.respond_to?(:time_zone) ? starts : starts.utc
        rule = RRule::Rule.new(rrule, dtstart: dtstart, tzid: tz, max_year: window_to.year + 1)
        rule.between(window_from, window_to, limit: MAX_OCCURRENCES).map { |time| starts.respond_to?(:time_zone) ? time : time.getlocal(starts.utc_offset) }
      end
    rescue StandardError => e
      Rails.logger.warn("calendar: an RRULE hob could not expand (#{rrule.inspect}): #{e.class}: #{e.message}")
      [ starts ]
    end

    def single(vevent, zone, recurrence_id: nil, recurring: false)
      starts = resolve(vevent.dtstart, vevent, zone)
      return nil if starts.nil?

      Occurrence.new(vevent: vevent, starts: starts, ends: starts + length(vevent, starts, zone), all_day: starts.is_a?(Date),
                     time_zone: zone_name(starts, vevent, zone), recurrence_id: recurrence_id, recurring: recurring)
    end

    # One occurrence of a series that no exception touched: the series'
    # event, moved to `starts`, as long as it ever was.
    def shifted(master, starts, zone)
      span = length(master, resolve(master.dtstart, master, zone), zone)
      Occurrence.new(vevent: master, starts: starts, ends: starts + span, all_day: starts.is_a?(Date),
                     time_zone: zone_name(starts, master, zone), recurrence_id: starts, recurring: true)
    end

    # How long an event lasts: days for an all-day one, seconds otherwise.
    # No DTEND and no DURATION is a day for a date and an instant for a time.
    def length(vevent, starts, zone)
      if vevent.dtend
        ends = resolve(vevent.dtend, vevent, zone)
        return starts.is_a?(Date) ? [ (ends.to_date - starts).to_i, 1 ].max : [ instant(ends, zone) - instant(starts, zone), 0 ].max if ends
      end
      if vevent.duration
        seconds = duration_seconds(vevent.duration)
        return starts.is_a?(Date) ? [ (seconds / 86_400.0).ceil, 1 ].max : seconds
      end
      starts.is_a?(Date) ? 1 : 0
    end

    def duration_seconds(duration)
      sign = duration.past ? -1 : 1
      sign * ((duration.weeks.to_i * 7 + duration.days.to_i) * 86_400 + duration.hours.to_i * 3600 + duration.minutes.to_i * 60 + duration.seconds.to_i)
    end

    # An iCalendar date or date-time as a Date, or a Time in its own zone.
    # icalendar has already applied a TZID it recognises (IANA names, and the
    # Windows ones Outlook writes) or a VTIMEZONE the document defines; a
    # time with no zone, or a TZID it could not place, is read in `zone`.
    def resolve(property, vevent, zone, ical_tzid: nil)
      value = property.respond_to?(:value) ? property.value : property
      return value if value.is_a?(Date) && !value.is_a?(DateTime)
      # icalendar's own wrapper adds days, not seconds, so it is unwrapped.
      return value.time_zone.at(value.to_time.to_i) if value.is_a?(ActiveSupport::TimeWithZone)
      return nil unless value.respond_to?(:to_time)

      utc = property.respond_to?(:value_ical) && property.value_ical.to_s.end_with?("Z")
      return value.to_time.utc if utc

      named = ical_tzid || tzid(property)
      return value.to_time if named && defined_zone?(vevent, named)

      zone.local(value.year, value.month, value.day, value.hour, value.min, value.sec)
    end

    def tzid(property)
      return nil unless property.respond_to?(:ical_params)

      Array(property.ical_params["tzid"]).first.presence
    end

    # Did the document define this zone itself (VTIMEZONE)? Then icalendar
    # has applied its offset and the time is right as it stands.
    def defined_zone?(vevent, name)
      calendar = vevent.parent
      calendar.respond_to?(:timezones) && calendar.timezones.any? { |timezone| timezone.tzid.to_s == name }
    end

    def zone_name(starts, vevent, zone)
      return nil if starts.is_a?(Date)
      return starts.time_zone.tzinfo.name if starts.respond_to?(:time_zone)

      named = tzid(vevent.dtstart)
      named && defined_zone?(vevent, named) ? named : zone.tzinfo.name
    end

    # A moment, for comparing: a date is its midnight in `zone`.
    def instant(value, zone)
      value.is_a?(Date) && !value.is_a?(DateTime) ? zone.local(value.year, value.month, value.day) : value.to_time
    end

    def overlaps?(occurrence, from, to, zone)
      starts = instant(occurrence.starts, zone)
      ends = instant(occurrence.ends, zone)
      starts < to && (ends > from || (ends == starts && starts >= from))
    end

    # What an occurrence is matched to its exception by: the UTC instant, or the day.
    def key(value)
      return nil if value.nil?

      value.is_a?(Date) && !value.is_a?(DateTime) ? value.strftime("%Y%m%d") : value.to_time.utc.strftime("%Y%m%dT%H%M%SZ")
    end

    def event(occurrence, calendar:, id_prefix:, zone:)
      vevent = occurrence.vevent
      status = vevent.status.to_s.downcase
      status = "confirmed" unless STATUSES.include?(status)
      recurrence = occurrence.recurring ? occurrence.recurrence_id : nil
      { "id" => [ "#{id_prefix}:#{vevent.uid}", key(recurrence) ].compact.join("@"),
        "calendar" => calendar, "uid" => vevent.uid.to_s, "recurrence_id" => recurrence && iso(recurrence, utc: true),
        "title" => text(vevent.summary), "location" => text(vevent.location),
        "description" => text(vevent.description, DESCRIPTION_LIMIT), "url" => text(vevent.url),
        "start" => iso(occurrence.starts), "end" => iso(occurrence.ends), "all_day" => occurrence.all_day,
        "time_zone" => occurrence.time_zone, "status" => status,
        "busy" => status != "cancelled" && vevent.transp.to_s.upcase != "TRANSPARENT", "recurring" => occurrence.recurring,
        "_starts" => instant(occurrence.starts, zone), "_ends" => instant(occurrence.ends, zone) }
    end

    # A date as a date; a time with its own offset, or in UTC when asked or
    # when UTC is its zone, so a UTC time always reads "Z".
    def iso(value, utc: false)
      return value.iso8601 if value.is_a?(Date) && !value.is_a?(DateTime)

      utc || value.utc_offset.zero? && zone_utc?(value) ? value.to_time.utc.iso8601 : value.iso8601
    end

    def zone_utc?(value)
      !value.respond_to?(:time_zone) || %w[UTC Etc/UTC Etc/GMT GMT].include?(value.time_zone.tzinfo.name)
    end

    def text(value, limit = TEXT_LIMIT)
      value = Array(value).first if value.is_a?(Array)
      value.to_s.strip.presence&.truncate(limit)
    end
  end
end
