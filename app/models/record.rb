# One document in a RecordCollection, as it is now (RECORDS.md). Never
# rewritten in place by anything but Records: every change is a
# RecordVersion first, and this row follows it. `realm` is the collection's,
# copied so RLS needs no join. `document` is a generated tsvector over the
# data's strings and numbers, for `q`.
class Record < ApplicationRecord
  belongs_to :collection, class_name: "RecordCollection", inverse_of: :records
  belongs_to :written_by, class_name: "Principal"
  has_many :versions, -> { order(version: :desc) }, class_name: "RecordVersion", dependent: :delete_all

  before_create { self.id ||= ULID.generate }

  scope :live, -> { where(retracted_at: nil) }

  def retracted?
    retracted_at.present?
  end

  # rec:<collection>:<key>
  def ref
    "rec:#{collection.name}:#{key}"
  end

  def as_json(*)
    { "id" => ref, "collection" => collection.name, "key" => key, "data" => data, "links" => links,
      "version" => version, "schema_version" => schema_version, "observed_at" => observed_at&.utc&.iso8601,
      "source" => source, "written_by" => { "principal" => written_by&.name, "surface" => surface },
      "created_at" => created_at&.utc&.iso8601, "updated_at" => updated_at&.utc&.iso8601 }
  end
end
