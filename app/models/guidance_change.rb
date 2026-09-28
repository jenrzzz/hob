# One edit to a sentinel_policies grant's guidance text (SENTINEL.md,
# "Policies"): the reviewer-facing scope of an already-held capability,
# widened or narrowed after the grant. Never deleted: with petitions and
# sentinel_requests, the audit trail — who approved it, when, the old text,
# the new text, and whether it came from a petition approval or an admin
# edit (`source`).
class GuidanceChange < ApplicationRecord
  SOURCES = %w[petition admin].freeze
  DECIDERS = %w[steward human].freeze

  belongs_to :sentinel_policy
  belongs_to :petition, optional: true
  belongs_to :decider, class_name: "Principal", optional: true

  validates :source, inclusion: { in: SOURCES }
  validates :decided_by, inclusion: { in: DECIDERS }
  validate :decider_is_human

  before_create { self.id ||= ULID.generate }

  scope :recent, -> { order(created_at: :desc) }

  private

  def decider_is_human
    errors.add(:decider, "must be a person") if decider && !decider.trusted?
  end
end
