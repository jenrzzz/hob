module Sentinel
  module Native
    # people.loop.dismiss: that was never a loop. A person confirms.
    class PeopleLoopDismiss < PeopleHandler
      CAPABILITY = {
        "name" => "people.loop.dismiss",
        "description" => "Ask to dismiss a loop that was never one: a sign-off that needed no answer, a sender who is a " \
                         "service. A person always confirms this. A loop answered in a way hob could not see (a call) is " \
                         "closed instead, with people.record and `closes`. `never_again: true` stops the handle it came in " \
                         "on from opening loops at all. The dismissal is kept as an event. Returns { loop: #{LOOP_JSON}, " \
                         "never_again }.",
        "kind" => "act",
        "realm" => "household",
        "requires_person" => true,
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "loop" => LOOP, "reason" => REASON,
            "never_again" => { "type" => "boolean", "description" => "This sender, this handle: never a loop again" }
          },
          "required" => %w[loop reason],
          "additionalProperties" => false
        }
      }.freeze

      def call
        People.dismiss(arguments, by: decider_writer)
      end
    end
  end
end
