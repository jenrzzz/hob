module Sentinel
  module Native
    # people.list: who the household knows, by filter.
    class PeopleList < PeopleHandler
      CAPABILITY = {
        "name" => "people.list",
        "description" => "List the people the household knows, a line each: { id, display_name, circles, automated, realm, " \
                         "whose, open_loops, contact: { last_inbound_at, last_outbound_at, last_contact_at, usual_gap_days, " \
                         "expected_days, days_since_contact, quiet }, next_date }. `q` matches names, aliases, and handles; " \
                         "`circle` a group's exact name; `has_open_loops`, `quiet` (gone silent for longer than twice their " \
                         "own usual gap), and `upcoming` (a key date within that many days) narrow it. Use people.get for " \
                         "the whole brief on one. Returns { people, count, matched, truncated, notice }.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "q" => { "type" => "string", "description" => "Words in a name, an alias, or a handle" },
            "circle" => { "type" => "string", "description" => "Only people in the group with this name" },
            "has_open_loops" => { "type" => "boolean" },
            "quiet" => { "type" => "boolean", "description" => "true: only those gone quiet past their own rhythm" },
            "upcoming" => { "type" => "integer", "minimum" => 0, "maximum" => 366, "description" => "A key date within this many days" },
            "whose" => WHOSE,
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => People::MAX_LIMIT, "description" => "Default 50" }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(People.list(arguments))
      end
    end
  end
end
