module Sentinel
  module Native
    # people.handle.add: this number is theirs too. A person confirms.
    class PeopleHandleAdd < PeopleHandler
      CAPABILITY = {
        "name" => "people.handle.add",
        "description" => "Ask to give a known person another phone number or email address. A person always confirms " \
                         "this: a handle on the wrong record sends one person's messages into another's brief. A handle " \
                         "already someone's is refused; if the two are one person, ask with people.merge instead. " \
                         "Returns { person: #{PERSON_JSON} }.",
        "kind" => "act",
        "realm" => "household",
        "requires_person" => true,
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "person" => PERSON,
            "handle" => { "type" => "string", "description" => "The phone number or email address" },
            "kind" => { "enum" => PersonHandle::KINDS, "description" => "Default: what it looks like" },
            "label" => { "type" => "string", "description" => "work, cell, ..." },
            "reason" => REASON
          },
          "required" => %w[person handle reason],
          "additionalProperties" => false
        }
      }.freeze

      def call
        People.add_handle(arguments, by: decider_writer)
      end
    end
  end
end
