module Sentinel
  module Native
    # records.changes: what moved in a collection since a cursor.
    class RecordsChanges < RecordsHandler
      CAPABILITY = {
        "name" => "records.changes",
        "description" => "What changed in a collection since you last asked, oldest first: one entry per new version, " \
                         "retracted: true when a person took the record away (drop your copy). Pass `since` the " \
                         "`next_since` the last call returned; leave it out to start from the beginning. A put that changed " \
                         "nothing is not a change. Returns { collection, changes: [{ key, version, retracted, at }], next_since }.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "collection" => COLLECTION,
            "since" => { "type" => "string", "description" => "The next_since from your last call" },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => Records::CHANGES_LIMIT }
          },
          "required" => %w[collection],
          "additionalProperties" => false
        }
      }.freeze

      def call
        Records.changes(arguments)
      end
    end
  end
end
