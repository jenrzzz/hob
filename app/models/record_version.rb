# One version of a Record, written once and never changed (RECORDS.md). The
# provenance is the request's, never the writer's say-so: who (principal),
# through what (surface), on whose authority (sentinel_request_id), for
# which work (mission_id). A retraction is a version too, with the data it
# hid, so a restore is another version and nothing is lost until a person
# purges the record.
#
# txid (the writing transaction, pg_current_xact_id() as a bigint) and seq order the
# changes feed; Records.changes reads them.
class RecordVersion < ApplicationRecord
  belongs_to :record
  belongs_to :collection, class_name: "RecordCollection"
  belongs_to :principal

  before_create { self.id ||= ULID.generate }

  def as_json(*)
    { "version" => version, "schema_version" => schema_version, "data" => data, "links" => links,
      "observed_at" => observed_at&.utc&.iso8601, "source" => source, "retracted" => retracted, "reason" => reason,
      "written_by" => { "principal" => principal&.name, "surface" => surface },
      "sentinel_request" => sentinel_request_id, "mission" => mission_id, "at" => created_at&.utc&.iso8601 }
  end
end
