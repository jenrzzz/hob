module Sentinel
  module Native
    # records.collection.update: change a collection's schema or
    # description. A person always confirms it.
    class RecordsCollectionUpdate < RecordsHandler
      CAPABILITY = {
        "name" => "records.collection.update",
        "description" => "Ask to change a collection's `schema` (null drops it) or `description`. A person always confirms " \
                         "it, seeing the old schema beside the new and how many records the new one would refuse. A schema " \
                         "change raises schema_version; records already written are not rewritten or re-checked, so to bring " \
                         "them into the new shape, put them again once this is confirmed. The name, key, and realm never " \
                         "change. Returns { collection: {...}, changed, refused }: `refused` counts current records the new " \
                         "schema would not accept.",
        "kind" => "act",
        "realm" => "household",
        "requires_person" => true,
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "collection" => COLLECTION, "reason" => REASON, "schema" => SCHEMA,
            "description" => { "type" => "string", "maxLength" => RecordCollection::DESCRIPTION_LIMIT }
          },
          "required" => %w[collection reason],
          "additionalProperties" => false
        }
      }.freeze

      def call
        Records.update_collection(arguments)
      end
    end
  end
end
