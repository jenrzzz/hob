module Sentinel
  module Native
    # records.collection.delete: retract a collection and everything in it.
    # A person always confirms it.
    class RecordsCollectionDelete < RecordsHandler
      CAPABILITY = {
        "name" => "records.collection.delete",
        "description" => "Ask to take a whole collection away, with every record in it. A person always confirms it, " \
                         "seeing how many records it holds. Nothing is lost until a person purges it, and its name stays " \
                         "taken until then. Returns { collection: {...}, records }: how many records went with it.",
        "kind" => "act",
        "realm" => "household",
        "requires_person" => true,
        "destructive" => true,
        "input_schema" => {
          "type" => "object",
          "properties" => { "collection" => COLLECTION, "reason" => REASON },
          "required" => %w[collection reason],
          "additionalProperties" => false
        }
      }.freeze

      def call
        Records.delete_collection(arguments, by: writer)
      end
    end
  end
end
