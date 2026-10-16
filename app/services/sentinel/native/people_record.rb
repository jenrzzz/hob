module Sentinel
  module Native
    # people.record: something that happened that no message shows.
    class PeopleRecord < PeopleHandler
      CAPABILITY = {
        "name" => "people.record",
        "description" => "Write down something that passed with a person (or a group) that hob will not see in a message: " \
                         "a call, a meeting, a gift, a favor, a promise. Texts are recorded on their own; do not record them " \
                         "again. `direction` is inbound (from them), outbound (from the household), or mutual. An outbound " \
                         "reply or a call or meeting closes the loops it answers, as a text would. `loop` opens one: " \
                         "{ kind: \"owed_action\", summary: \"send Tara the ADU photos\" }. `closes` closes loops you name, " \
                         "with this event as what closed them (\"sent the photos\"); a loop that was never a loop is for " \
                         "people.loop.dismiss. Provenance is yours: you are recorded as who said so. Returns { event: " \
                         "#{EVENT_JSON}, opened, closed, notice }.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "person" => PERSON, "group" => GROUP,
            "kind" => { "enum" => PeopleEvent::KINDS - %w[dismissed] },
            "direction" => { "enum" => PeopleEvent::DIRECTIONS, "description" => "Required for everything but a note" },
            "channel" => { "enum" => PeopleEvent::CHANNELS },
            "at" => { "type" => "string", "description" => "ISO 8601: when it happened, if not now" },
            "summary" => { "type" => "string", "maxLength" => PeopleEvent::SUMMARY_LIMIT, "description" => "Short, human-readable" },
            "source_ref" => { "type" => "string", "description" => "The id of what this came from, if anything (a mail id, a calendar event)" },
            "supersedes" => { "type" => "string", "description" => "An event this one corrects" },
            "loop" => { "type" => "object", "properties" => { "kind" => { "enum" => PeopleLoop::KINDS }, "summary" => { "type" => "string" } },
                        "required" => %w[kind], "additionalProperties" => false },
            "closes" => { "type" => "array", "items" => { "type" => "string" }, "maxItems" => People::CLOSES_LIMIT },
            "realm" => REALM, "whose" => WHOSE
          },
          "required" => %w[kind],
          "additionalProperties" => false
        }
      }.freeze

      def call
        People.record(arguments, by: writer)
      end
    end
  end
end
