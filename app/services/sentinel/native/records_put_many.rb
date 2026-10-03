module Sentinel
  module Native
    # records.put_many: up to 100 puts into one collection, all or nothing.
    class RecordsPutMany < RecordsHandler
      CAPABILITY = {
        "name" => "records.put_many",
        "description" => "Write up to #{Records::BATCH_LIMIT} records into one collection at once, all or nothing: one that " \
                         "will not do refuses the batch and says which. Each is written as records.put writes one; unchanged " \
                         "ones cost nothing. Returns { records: [#{RECORD}], changed, unchanged, notice }.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "collection" => COLLECTION,
            "records" => {
              "type" => "array", "minItems" => 1, "maxItems" => Records::BATCH_LIMIT,
              "items" => { "type" => "object", "properties" => { "data" => DATA, "links" => LINKS, "source" => SOURCE,
                                                                  "observed_at" => OBSERVED_AT },
                           "required" => %w[data], "additionalProperties" => false }
            }
          },
          "required" => %w[collection records],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Records.put_many(arguments, by: writer))
      end
    end
  end
end
