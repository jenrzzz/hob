module Sentinel
  module Native
    # people.merge: two records, one person. A person confirms.
    class PeopleMerge < PeopleHandler
      CAPABILITY = {
        "name" => "people.merge",
        "description" => "Ask to merge two records that are one person (two numbers, one human). A person always confirms " \
                         "this, and should: a wrong merge leaks one person's loops into another's brief, where a missed one " \
                         "only duplicates. Say why in `reason` (\"same name in Contacts; the old number texted 'new number, " \
                         "it's Eugene'\"). `from` answers as `into` afterwards: its handles, circles, and open loops move, " \
                         "and its events and notes are read with `into`'s. `into` must be at least as high a realm as " \
                         "`from`. Returns { person: #{PERSON_JSON}, merged }.",
        "kind" => "act",
        "realm" => "household",
        "requires_person" => true,
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "into" => PERSON.merge("description" => "The record to keep: an id, or a handle"),
            "from" => PERSON.merge("description" => "The record that becomes it: an id, or a handle"),
            "reason" => REASON
          },
          "required" => %w[into from reason],
          "additionalProperties" => false
        }
      }.freeze

      def call
        People.merge(arguments, by: decider_writer)
      end
    end
  end
end
