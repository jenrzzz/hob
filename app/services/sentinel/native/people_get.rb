module Sentinel
  module Native
    # people.get: the brief on one person.
    class PeopleGet < PeopleHandler
      CAPABILITY = {
        "name" => "people.get",
        "description" => "The brief on one person, for before you answer them: { person: #{PERSON_JSON}, contact: " \
                         "{ last_inbound_at, last_outbound_at, last_contact_at, usual_gap_days, expected_days, " \
                         "days_since_contact, quiet }, upcoming_dates, groups, mutual (people in their groups), open_loops: " \
                         "[#{LOOP_JSON}], recent_events: [#{EVENT_JSON}] (1:1 only, newest first), notes: [{ id, body, by, " \
                         "realm, at }], merged_from, notice }. Everything is what your clearance can see. An event's " \
                         "source.ref names the message it came from (text.messages can read it); hob keeps no copy.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "person" => PERSON,
            "events" => { "type" => "integer", "minimum" => 0, "maximum" => 200, "description" => "How many recent events (default 20)" }
          },
          "required" => %w[person],
          "additionalProperties" => false
        }
      }.freeze

      def call
        People.get(arguments)
      end
    end
  end
end
