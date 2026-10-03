module Sentinel
  module Native
    # records.query: records in a collection, filtered.
    class RecordsQuery < RecordsHandler
      CAPABILITY = {
        "name" => "records.query",
        "description" => "Find records in a collection. `match` is an object the document must contain (Postgres @>: " \
                         "{\"items\": [{\"asin\": \"B0...\"}]} finds orders holding that item); `linked` a ref the record " \
                         "links to (which order is budget:house-ynab:<id>?); `q` words that must all appear in the document. " \
                         "Sort by updated (the default, newest first), observed, key, or any top-level field; - reverses. " \
                         "`matched` counts everything that matched, not only the `limit` returned. Returns { collection, " \
                         "records: [#{RECORD}], count, matched, truncated, notice }.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "collection" => COLLECTION,
            "match" => { "type" => "object", "description" => "An object the document must contain" },
            "linked" => { "type" => "string", "description" => "A ref the record must link to" },
            "q" => { "type" => "string", "description" => "Words that must all appear in the document's text" },
            "observed_after" => { "type" => "string", "description" => "ISO 8601 time or date" },
            "observed_before" => { "type" => "string", "description" => "ISO 8601 time or date" },
            "updated_after" => { "type" => "string", "description" => "ISO 8601 time or date" },
            "sort" => { "type" => "string", "description" => "updated, observed, key, or a top-level field; prefix - to reverse. Default -updated" },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => Records::MAX_LIMIT, "description" => "Default #{Records::DEFAULT_LIMIT}" }
          },
          "required" => %w[collection],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Records.query(arguments))
      end
    end
  end
end
