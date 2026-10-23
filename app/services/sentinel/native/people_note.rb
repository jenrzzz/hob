module Sentinel
  module Native
    # people.note: what you know about someone, with your name on it.
    class PeopleNote < PeopleHandler
      CAPABILITY = {
        "name" => "people.note",
        "description" => "Add a note to a person or a group: how they connect, what to ask about, what matters to them " \
                         "(\"moved away in 2023; ask about the new place\"). A note is an opinion with your byline, read " \
                         "back as one. Notes are kept, never edited: write a new one when things change. `realm` defaults " \
                         "to your clearance; write it no lower than where you learned it. Returns { note: { id, person, " \
                         "group, body, by, realm, at } }.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "person" => PERSON, "group" => GROUP,
            "body" => { "type" => "string", "maxLength" => ::PeopleNote::BODY_LIMIT },
            "realm" => REALM
          },
          "required" => %w[body],
          "additionalProperties" => false
        }
      }.freeze

      def call
        People.note(arguments, by: writer)
      end
    end
  end
end
