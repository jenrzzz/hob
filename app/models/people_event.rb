# One thing that passed between the household and a person, or in a group
# (PEOPLE.md). Append-only: never updated, and a correction is a later event
# naming the one it supersedes. `source_kind` and `source_ref` say where it
# came from (the text's id, not its body); `recorded_by` and `surface` say
# who wrote it down, from the request, never from the arguments. `principal`
# is whose side of the relationship it was on.
#
# Interactions have a direction; a note or a dismissal is about the
# relationship, not a contact in it, and has none.
class PeopleEvent < ApplicationRecord
  INTERACTIONS = %w[reached_out replied met called gift_given gift_received favor_done favor_owed].freeze
  KINDS = (INTERACTIONS + %w[note dismissed]).freeze
  DIRECTIONS = %w[inbound outbound mutual].freeze
  CHANNELS = %w[text email call in_person video other].freeze
  SOURCE_KINDS = %w[text mail calendar dictated agent].freeze
  SUMMARY_LIMIT = 500

  belongs_to :person, optional: true
  belongs_to :group, class_name: "PeopleGroup", optional: true
  belongs_to :principal, optional: true
  belongs_to :recorded_by, class_name: "Principal"
  belongs_to :supersedes, class_name: "PeopleEvent", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :direction, inclusion: { in: DIRECTIONS }, if: :interaction?
  validates :direction, absence: true, unless: :interaction?
  validates :channel, inclusion: { in: CHANNELS }, allow_nil: true
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :summary, length: { maximum: SUMMARY_LIMIT }, allow_nil: true
  validates :realm, :at, presence: true
  validate :about_someone

  before_create { self.id ||= ULID.generate }
  before_update { raise ActiveRecord::ReadOnlyRecord, "people events are append-only; record a correction instead" }

  scope :interactions, -> { where(kind: INTERACTIONS) }

  def interaction?
    INTERACTIONS.include?(kind)
  end

  def as_json(*)
    { "id" => id, "person" => person_id, "group" => group_id, "at" => at&.utc&.iso8601, "kind" => kind,
      "direction" => direction, "channel" => channel, "summary" => summary,
      "source" => { "kind" => source_kind, "ref" => source_ref, "by" => recorded_by&.name, "surface" => surface }.compact,
      "whose" => principal&.name, "supersedes" => supersedes_id, "realm" => realm }.compact
  end

  private

  def about_someone
    errors.add(:base, "an event is about a person or a group") if person_id.nil? && group_id.nil?
  end
end
