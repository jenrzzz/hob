module Sentinel
  module Native
    # records.get: one record, or one version of it.
    class RecordsGet < RecordsHandler
      CAPABILITY = {
        "name" => "records.get",
        "description" => "Read one record by its collection and key; `version` reads an earlier version (records.history " \
                         "lists them). A retracted record is not found. Returns { record: #{RECORD}, notice }.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "collection" => COLLECTION, "key" => KEY,
                            "version" => { "type" => "integer", "minimum" => 1, "description" => "An earlier version to read" } },
          "required" => %w[collection key],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Records.get(arguments))
      end
    end
  end
end
