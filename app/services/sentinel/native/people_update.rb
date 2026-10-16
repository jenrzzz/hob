module Sentinel
  module Native
    # people.update: what a person is called, their circles and dates.
    class PeopleUpdate < PeopleHandler
      CAPABILITY = {
        "name" => "people.update",
        "description" => "Change what hob knows of a person: display_name, names (the whole set), circles (the whole set) " \
                         "or add_circles/remove_circles, key_dates (the whole set), automated, cadence_days (null: judge " \
                         "from their own history). Only what you name changes. Handles are added with people.handle.add, " \
                         "which a person confirms. Returns { person: #{PERSON_JSON} }.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "person" => PERSON,
            "display_name" => { "type" => "string", "maxLength" => Person::DISPLAY_NAME_LIMIT },
            "names" => { "type" => "array", "items" => { "type" => "string" } },
            "circles" => CIRCLES, "add_circles" => CIRCLES, "remove_circles" => CIRCLES, "key_dates" => KEY_DATES,
            "automated" => { "type" => "boolean" },
            "cadence_days" => { "type" => %w[integer null], "minimum" => 1, "maximum" => 3650 }
          },
          "required" => %w[person],
          "additionalProperties" => false
        }
      }.freeze

      def call
        { "person" => People.update(arguments, by: writer).as_json }
      end
    end
  end
end
