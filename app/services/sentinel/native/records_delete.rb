module Sentinel
  module Native
    # records.delete: retract one record. A person always confirms it.
    class RecordsDelete < RecordsHandler
      CAPABILITY = {
        "name" => "records.delete",
        "description" => "Ask to take a record away. A person always confirms it. The record leaves every read and cannot " \
                         "be written again, but nothing is lost: its history stays and a person can restore it. A record " \
                         "that is only wrong is not deleted: put it again, corrected. Returns { record: {...}, retracted }.",
        "kind" => "act",
        "realm" => "household",
        "requires_person" => true,
        "destructive" => true,
        "input_schema" => {
          "type" => "object",
          "properties" => { "collection" => COLLECTION, "key" => KEY, "reason" => REASON },
          "required" => %w[collection key reason],
          "additionalProperties" => false
        }
      }.freeze

      def call
        Records.delete(arguments, by: writer)
      end
    end
  end
end
