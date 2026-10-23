module Sentinel
  module Native
    # people.loops: what is still open, oldest first.
    class PeopleLoops < PeopleHandler
      CAPABILITY = {
        "name" => "people.loops",
        "description" => "What is still open with people, the longest-waiting first: a reach-out not answered " \
                         "(unanswered_inbound), a reply or a favor owed (owed_reply, owed_action), an answer awaited " \
                         "(awaiting_them). hob opens and closes them from texts as they come and go; nobody needs to say " \
                         "\"handled\". `age_days` runs from the first unanswered message. By default the open ones not " \
                         "snoozed; `state` asks for others. Whether and when to nudge someone about a loop is yours to " \
                         "decide; hob only keeps it. Returns { loops: [#{LOOP_JSON}], count, matched, truncated, notice }.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "person" => PERSON, "group" => GROUP,
            "kind" => { "anyOf" => [ { "enum" => PeopleLoop::KINDS }, { "type" => "array", "items" => { "enum" => PeopleLoop::KINDS } } ] },
            "state" => { "enum" => People::LOOP_STATES, "description" => "Default open (and not snoozed)" },
            "older_than" => { "type" => "integer", "minimum" => 0, "description" => "Opened at least this many days ago" },
            "whose" => WHOSE,
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => People::MAX_LIMIT, "description" => "Default 50" }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        People.loops(arguments)
      end
    end
  end
end
