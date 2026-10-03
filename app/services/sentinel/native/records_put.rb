module Sentinel
  module Native
    # records.put: write one record, by its key.
    class RecordsPut < RecordsHandler
      CAPABILITY = {
        "name" => "records.put",
        "description" => "Write one record into a collection. The record is found by its key, a field of `data`: a new key " \
                         "makes a record, a known one a new version of it. A put that changes neither data nor links writes " \
                         "nothing (changed: false) and only notes that you saw it again, so re-reading a whole history and " \
                         "putting all of it is cheap and safe. `if_version` refuses the write unless the record is still at " \
                         "that version (0: it must not exist yet). A record a person retracted cannot be written again. " \
                         "Returns { record: #{RECORD}, changed, notice }.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "collection" => COLLECTION, "data" => DATA, "links" => LINKS, "source" => SOURCE, "observed_at" => OBSERVED_AT,
            "if_version" => { "type" => "integer", "minimum" => 0, "description" => "Write only if the record is at this version" }
          },
          "required" => %w[collection data],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Records.put(arguments, by: writer))
      end
    end
  end
end
