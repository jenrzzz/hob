# A named collection of what the household's agents keep (RECORDS.md). The
# row says whose the collection is, the realm of every record in it, which
# top-level field of a document is its key, and optionally the JSON Schema
# a document must meet to be written.
#
# `realm` is the realm of everything in the collection and RLS enforces it
# here and on records and record_versions: a household request cannot see a
# personal collection, so cannot name it, so cannot reach a record in it.
# name, key_path, and realm never change once the collection exists (refs
# carry the name; the key is what makes two writes the same record; moving
# a realm is declassification). The schema and description may, and every
# schema change is a new schema_version.
#
# A retracted collection is gone from every read but nothing in it is lost:
# a person restores it, or purges it for good (Records.purge_collection!).
class RecordCollection < ApplicationRecord
  NAME_FORMAT = TodoBackend::NAME_FORMAT
  KEY_FORMAT = /\A[A-Za-z_][A-Za-z0-9_]*\z/
  DESCRIPTION_LIMIT = 1000

  belongs_to :principal
  belongs_to :proposed_by, class_name: "Principal", optional: true
  belongs_to :retracted_by, class_name: "Principal", optional: true
  has_many :records, foreign_key: :collection_id, inverse_of: :collection, dependent: :restrict_with_exception
  has_many :record_versions, foreign_key: :collection_id, dependent: :restrict_with_exception

  validates :name, presence: true, uniqueness: true, format: { with: NAME_FORMAT, message: "must be a lowercase slug, like amazon-orders" }
  validates :key_path, presence: true, format: { with: KEY_FORMAT, message: "must be the name of a top-level field, like order_id" }
  validates :description, presence: true, length: { maximum: DESCRIPTION_LIMIT }
  validates :realm, presence: true
  validate :realm_known
  validate :owned_by_a_person
  validate :proposed_by_an_agent
  validate :schema_is_a_schema
  validate :fixed_once_made, on: :update

  before_create { self.id ||= ULID.generate }

  scope :live, -> { where(retracted_at: nil) }
  scope :retracted, -> { where.not(retracted_at: nil) }

  def retracted?
    retracted_at.present?
  end

  # The compiled schema, or nil when the collection has none.
  def schemer
    return nil if schema.nil?

    @schemer = nil if @schemer_for != schema
    @schemer_for = schema
    @schemer ||= JSONSchemer.schema(schema)
  end

  # What is wrong with `data` under this collection's schema: messages, empty when nothing.
  def schema_errors(data)
    return [] if schema.nil?

    schemer.validate(data).first(5).map { |error| error["error"] }
  end

  def as_json(*)
    { "name" => name, "realm" => realm, "owner" => principal&.name, "key" => key_path, "schema" => schema,
      "schema_version" => schema_version, "description" => description, "proposed_by" => proposed_by&.name,
      "count" => records.where(retracted_at: nil).count, "updated_at" => updated_at, "created_at" => created_at }
  end

  private

  def realm_known
    Realm.rank_of(realm) if realm.present?
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def owned_by_a_person
    errors.add(:principal, "must be a person: a person says what the household keeps") if principal && !principal.trusted?
  end

  def proposed_by_an_agent
    errors.add(:proposed_by, "must be an agent") if proposed_by && !proposed_by.agent?
  end

  def schema_is_a_schema
    return if schema.nil?
    return errors.add(:schema, "must be a JSON Schema object") unless schema.is_a?(Hash)

    problems = JSONSchemer.validate_schema(schema).first(3).map { |error| error["error"] }
    errors.add(:schema, "is not a valid JSON Schema: #{problems.join('; ')}") if problems.any?
  rescue StandardError => e
    errors.add(:schema, "is not a valid JSON Schema: #{e.message}")
  end

  def fixed_once_made
    %w[name key_path realm].each do |attr|
      errors.add(attr, "cannot change once the collection exists") if will_save_change_to_attribute?(attr)
    end
  end
end
