# One short-lived statement about a household person's present moment
# (SITUATION.md). Rows are append-only: a new value supersedes an older one,
# and an ending is a tombstone row with `ended_at` set. This keeps provenance
# and makes the future situation.changes feed honest.
class SituationObservation < ApplicationRecord
  KINDS = %w[location sleep company availability activity energy mood health plans topic].freeze
  BASES = %w[sensed stated inferred].freeze
  SOURCE_KINDS = %w[device automation surface agent person].freeze

  belongs_to :person, class_name: "Principal"
  belongs_to :ended_by, class_name: "Principal", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :basis, inclusion: { in: BASES }
  validates :realm, :observed_at, :expires_at, presence: true
  validates :slot, presence: true, if: :topic?
  validates :slot, absence: true, unless: :topic?
  validate :person_is_human
  validate :realm_known
  validate :source_shaped
  validate :times_are_ordered

  before_create { self.id ||= ULID.generate }
  before_update { raise ActiveRecord::ReadOnlyRecord, "situation observations are append-only; record a new observation instead" }

  scope :for_person, ->(person) { where(person: person) }

  def topic?
    kind == "topic"
  end

  def tombstone?
    ended_at.present?
  end

  def ttl
    expires_at - observed_at
  end

  def stale?(now = Time.current)
    !topic? && !tombstone? && expires_at < now && now <= expires_at + ttl
  end

  def visible_at?(now = Time.current)
    return false if tombstone?
    return expires_at >= now if topic?

    now <= expires_at + ttl
  end

  private

  def person_is_human
    errors.add(:person, "must be a household person") unless person&.trusted?
  end

  def realm_known
    Realm.rank_of(realm) if realm.present?
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def source_shaped
    unless source.is_a?(Hash) && SOURCE_KINDS.include?(source["kind"]) && source["by"].present? && source["surface"].present?
      errors.add(:source, "must name its kind, writer, and surface")
    end
  end

  def times_are_ordered
    return if observed_at.blank? || expires_at.blank?

    if tombstone?
      errors.add(:ended_at, "must be when the ending was observed") unless ended_at == observed_at && expires_at == observed_at
    elsif expires_at <= observed_at
      errors.add(:expires_at, "must be after observed_at")
    end
  end
end
