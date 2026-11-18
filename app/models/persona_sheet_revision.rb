# One proposed change to a persona's sheet (MEMORY.md, "The sheet"): a list
# of ops, the observations that justify it, who proposed it, and whether it
# was applied. The sheet at a clearance is the applied revisions at or below
# it, replayed in the order they were applied.
class PersonaSheetRevision < ApplicationRecord
  KINDS = %w[edit rollback].freeze
  STATUSES = %w[proposed applied rejected reverted].freeze

  belongs_to :persona
  belongs_to :proposed_by, class_name: "Principal", optional: true
  belongs_to :decided_by, class_name: "Principal", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :realm, :proposed_via, presence: true
  validates :citations, presence: { message: "must name the observations that justify the change" }, if: -> { kind == "edit" }
  validate :ops_shaped, if: -> { kind == "edit" }

  before_create { self.id ||= ULID.generate }

  scope :applied, -> { where(status: "applied").order(:applied_seq) }

  def as_json(*)
    { id: id, persona: persona.key, version: version, kind: kind, realm: realm, status: status, ops: ops,
      rationale: rationale, citations: citations, proposed_by: proposed_by&.name, proposed_via: proposed_via,
      provenance: provenance, rollback_to: rollback_to, decided_by: decided_by&.name, decided_at: decided_at,
      reverted_by: reverted_by_id, created_at: created_at }
  end

  private

  def ops_shaped
    PersonaSheet.validate_ops!(ops)
  rescue Gateway::Invalid => e
    errors.add(:ops, e.message)
  end
end
