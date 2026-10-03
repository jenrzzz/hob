module Sentinel
  module Native
    # records.collection.create: ask for a new collection. Only a person
    # approves it, and that person owns it.
    class RecordsCollectionCreate < RecordsHandler
      CAPABILITY = {
        "name" => "records.collection.create",
        "description" => "Ask for a new record collection. A person always confirms this and becomes its owner, so ask " \
                         "before you start the work that needs it, and wait for the answer. Give a lowercase slug `name` " \
                         "(it is in every ref to its records and never changes), the `key` field that identifies a document " \
                         "(order_id; never changes), a `description` of what it holds and why, and the `schema` you mean to " \
                         "write (a JSON Schema; recommended). `realm` defaults to yours. Returns { collection: { name, realm, " \
                         "owner, key, schema, schema_version, description, proposed_by, count, created_at, updated_at } }.",
        "kind" => "act",
        "realm" => "household",
        "requires_person" => true,
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "name" => { "type" => "string", "description" => "A lowercase slug: amazon-orders" },
            "key" => { "type" => "string", "description" => "The top-level field of every document that identifies it" },
            "description" => { "type" => "string", "maxLength" => RecordCollection::DESCRIPTION_LIMIT },
            "schema" => SCHEMA,
            "realm" => { "type" => "string", "description" => "household, personal, or intimate; at most your own. Default: yours" }
          },
          "required" => %w[name key description],
          "additionalProperties" => false
        }
      }.freeze

      def call
        collection = Records.create_collection(arguments, owner: person, proposed_by: agent, request_id: request.id)
        { "collection" => collection.as_json }
      end
    end
  end
end
