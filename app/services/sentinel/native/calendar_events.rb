module Sentinel
  module Native
    # calendar.events: what is on the calendars, for a window. Which
    # calendars that reaches is RLS's answer; the handler adds nothing.
    class CalendarEvents < CalendarHandler
      TIME = "A date (2026-10-06: midnight where the household is) or a time with its offset (2026-10-06T15:00:00-07:00)".freeze

      CAPABILITY = {
        "name" => "calendar.events",
        "description" => "Events on the household calendars visible at the agent's clearance that overlap `from`...`to`, " \
                         "soonest first: the next #{Calendars::DEFAULT_DAYS} days when no window is given, at most " \
                         "#{Calendars::MAX_DAYS} days at a time. Each occurrence of a repeating event is its own event, with " \
                         "the series' `uid` and its own `recurrence_id`. Returns { from, to, events: [#{EVENT}], count, " \
                         "matched, truncated, unavailable: [{ backend, error }], notice }. A timed event's start and end carry " \
                         "the offset of the zone it was set in (`time_zone`); an all-day event's are dates, the end exclusive. " \
                         "`busy: false` is an event marked free. Some calendars are shared free/busy only: their events have " \
                         "start, end, and busy, and a null title, location, description, and url. Cancelled events are left " \
                         "out unless `cancelled: true`.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "backend" => BACKEND,
            "calendar" => { "type" => %w[string array], "items" => { "type" => "string" },
                            "description" => "Only this calendar, or these (ids from calendar.calendars, all in one backend)" },
            "from" => { "type" => "string", "description" => "#{TIME}. Default: now" },
            "to" => { "type" => "string", "description" => "#{TIME}. Default: #{Calendars::DEFAULT_DAYS} days after from" },
            "q" => { "type" => "string", "description" => "Words that must all appear in the title, location, description, or url" },
            "cancelled" => { "type" => "boolean", "description" => "true: cancelled events too", "default" => false },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => Calendars::MAX_LIMIT, "default" => Calendars::DEFAULT_LIMIT }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        result = Calendars.events(arguments)
        noticed(result.merge("count" => result["events"].size))
      end
    end
  end
end
