module Sentinel
  module Native
    # records.history: every version of a record, and who wrote each.
    class RecordsHistory < RecordsHandler
      CAPABILITY = {
        "name" => "records.history",
        "description" => "Every version of one record, newest first: its data and links then, the schema_version it was " \
                         "written under, who wrote it through what surface, the sentinel request and mission it came with, " \
                         "and any retraction or restore with its reason. Returns { id, versions: [{ version, schema_version, " \
                         "data, links, observed_at, source, retracted, reason, written_by: { principal, surface }, " \
                         "sentinel_request, mission, at }], notice }.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "collection" => COLLECTION, "key" => KEY },
          "required" => %w[collection key],
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Records.history(arguments))
      end
    end
  end
end
