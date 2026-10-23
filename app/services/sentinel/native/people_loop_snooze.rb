module Sentinel
  module Native
    # people.loop.snooze: not now.
    class PeopleLoopSnooze < PeopleHandler
      CAPABILITY = {
        "name" => "people.loop.snooze",
        "description" => "Hide an open loop from people.loops until a time, when a person said \"not now\" or \"after the " \
                         "weekend\". It stays open, and a new message from them wakes it early. `until: null` wakes it now. " \
                         "Returns { loop: #{LOOP_JSON} }.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "loop" => LOOP,
            "until" => { "type" => %w[string null], "description" => "ISO 8601, or a date (midnight where the household is)" }
          },
          "required" => %w[loop until],
          "additionalProperties" => false
        }
      }.freeze

      def call
        People.snooze(arguments, by: writer)
      end
    end
  end
end
