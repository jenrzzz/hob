module Sentinel
  module Native
    # What the calendar.* handlers share (CALENDARS.md). They are thin:
    # Calendars does the work, at the agent's clearance, so the calendars an
    # agent can reach are the ones RLS shows it and the handlers add no
    # realm logic of their own. Everything handed back carries
    # Calendars::NOTICE, since anyone who can send an invitation can write an
    # event's title. What Calendars raises (NotFound, Invalid, Forbidden,
    # Unavailable) fails the request with its message.
    class CalendarHandler < Base
      BACKEND = { "type" => "string", "description" => "Only this backend (a name from calendar.calendars)" }.freeze
      CALENDAR = "{ id, backend, name, color, read_only, time_zone }".freeze
      EVENT = "{ id, backend, calendar: { id, name }, uid, recurrence_id, title, location, description, url, start, end, " \
              "all_day, time_zone, status, busy, recurring }".freeze

      private

      def noticed(result)
        result.merge("notice" => Calendars::NOTICE)
      end
    end
  end
end
