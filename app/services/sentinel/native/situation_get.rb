module Sentinel
  module Native
    # situation.get: the current, expiring state of one household person, or
    # the visible facets of everybody when person is omitted.
    class SituationGet < Base
      CAPABILITY = {
        "name" => "situation.get",
        "description" => "Read a household person's present situation: expiring facets such as location, sleep, " \
                         "company, availability, activity, energy, mood, health, and plans; attributed topics; and " \
                         "derived local time and device. Give person for their facets and topics. Omit it for every " \
                         "visible person's facets, with topics withheld. Every item carries its basis, writer, age, " \
                         "in seconds, and realm. Returns { as_of, people: [{ person, facets, topics, derived }], notice }.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "person" => { "type" => "string", "description" => "A household person's principal name; omit for everybody's facets" }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        Situation.get(arguments, requester: request.principal, surface: request.surface)
      end
    end
  end
end
