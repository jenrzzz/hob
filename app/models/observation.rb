# One timestamped fact about an entity, with a realm and its provenance
# (MEMORY.md). Never rewritten: a correction supersedes it with a new row, and
# a retirement stamps it. Only those lifecycle columns ever change, once.
class Observation < ApplicationRecord
  BODY_LIMIT = 4_000
  KIND_FORMAT = /\A[a-z][a-z0-9_.-]{0,63}\z/
  LIFECYCLE = %w[superseded_by_id retired_at retired_by retire_reason].freeze

  belongs_to :entity
  belongs_to :author_entity, class_name: "Entity", optional: true
  belongs_to :principal, optional: true

  validates :body, presence: true, length: { maximum: BODY_LIMIT }
  validates :kind, format: { with: KIND_FORMAT }
  validates :realm, :surface, :observed_at, presence: true
  validate :realm_known
  validate :evidence_shaped

  before_create { self.id ||= ULID.generate }
  before_update :only_lifecycle_changes

  scope :current, -> { where(retired_at: nil, superseded_by_id: nil) }

  def current?
    retired_at.nil? && superseded_by_id.nil?
  end

  def status
    if superseded_by_id then "superseded"
    elsif retired_at then "retired"
    else "current"
    end
  end

  def as_json(*)
    {
      id: id, about: entity_id, author: author_entity_id, kind: kind, body: body, realm: realm,
      observed_at: observed_at, status: status, supersedes: supersedes_id, superseded_by: superseded_by_id,
      retired_at: retired_at, retired_by: retired_by, retire_reason: retire_reason,
      evidence: evidence, embedded: embedding_model,
      provenance: { principal: principal&.name, surface: surface, conversation: conversation_id, node: node_hash }
                    .merge(source.symbolize_keys).compact,
      created_at: created_at
    }
  end

  private

  def realm_known
    Realm.rank_of(realm) if realm.present?
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def evidence_shaped
    return if evidence.all? { |ref| ref.to_s.match?(Entity::REF_FORMAT) } && evidence.size <= 50

    errors.add(:evidence, "is at most 50 refs, each <kind>:<id>")
  end

  def only_lifecycle_changes
    changed = changes_to_save.keys - LIFECYCLE
    raise ActiveRecord::ReadOnlyRecord, "observations are never rewritten; supersede instead (#{changed.join(', ')})" if changed.any?
    raise ActiveRecord::ReadOnlyRecord, "observation #{id} is already #{status_was}" unless retired_at_was.nil? && superseded_by_id_was.nil?
  end

  def status_was
    superseded_by_id_was ? "superseded" : "retired"
  end
end
