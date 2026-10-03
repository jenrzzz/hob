module Sentinel
  module Native
    # records.collections: what the household keeps that this agent can see.
    class RecordsCollections < RecordsHandler
      CAPABILITY = {
        "name" => "records.collections",
        "description" => "List the record collections you can see: the household's store of structured documents agents " \
                         "keep, like orders read off a site. Each has a name, a realm, a key (the field of a document that " \
                         "identifies it), a JSON Schema its documents meet (or null), schema_version, a description, and " \
                         "how many records it holds. Look here before writing, and before asking for a new collection. " \
                         "Returns { collections: [{ name, realm, owner, key, schema, schema_version, description, " \
                         "proposed_by, count, created_at, updated_at }] }.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => { "type" => "object", "properties" => {}, "additionalProperties" => false }
      }.freeze

      def call
        Records.collections
      end
    end
  end
end
