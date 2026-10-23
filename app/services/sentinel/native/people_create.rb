module Sentinel
  module Native
    # people.create: someone hob has not met.
    class PeopleCreate < PeopleHandler
      CAPABILITY = {
        "name" => "people.create",
        "description" => "Add a person hob does not know yet. Look with people.list first: hob makes people on its own " \
                         "from the texts it sees, so they may be there already under a number. Handles must be new to hob; " \
                         "one that is already someone's is refused, and if they are one person, ask with people.merge. A " \
                         "person with a short-code or no-reply handle is marked automated and never opens a loop. `realm` " \
                         "defaults to your clearance. Returns { person: #{PERSON_JSON} }.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "display_name" => { "type" => "string", "maxLength" => Person::DISPLAY_NAME_LIMIT },
            "names" => { "type" => "array", "items" => { "type" => "string" }, "description" => "What else they are called" },
            "handles" => HANDLES, "circles" => CIRCLES, "key_dates" => KEY_DATES,
            "automated" => { "type" => "boolean", "description" => "A service, not a person: never opens a loop" },
            "cadence_days" => { "type" => "integer", "minimum" => 1, "maximum" => 3650,
                                "description" => "How often to expect contact, if a person said (\"we talk monthly\": 30)" },
            "realm" => REALM, "whose" => WHOSE
          },
          "required" => %w[display_name],
          "additionalProperties" => false
        }
      }.freeze

      def call
        { "person" => People.create(arguments, by: writer).as_json }
      end
    end
  end
end
