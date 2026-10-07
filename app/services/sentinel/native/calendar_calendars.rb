module Sentinel
  module Native
    # calendar.calendars: the calendars visible at the agent's clearance.
    class CalendarCalendars < CalendarHandler
      CAPABILITY = {
        "name" => "calendar.calendars",
        "description" => "The household calendars visible at the agent's clearance (Fastmail, subscribed .ics feeds, by way " \
                         "of hob). Returns { calendars: [#{CALENDAR}], unavailable: [{ backend, error }], notice }. A calendar " \
                         "id is what calendar.events takes as `calendar`. A backend that could not be reached is named in " \
                         "`unavailable`: its calendars are missing from the answer, not from the world.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "backend" => BACKEND },
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Calendars.calendars(arguments))
      end
    end
  end
end
