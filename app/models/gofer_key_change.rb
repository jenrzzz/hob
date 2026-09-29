# One edit to a gofer key's domains (BROWSE.md), from GoferKeysController.
# `domains_before` is best-effort: gofer has no endpoint to read a key's
# current domains, so it is the previous change's `domains_after` for this
# browser and key, or null the first time hob touches one.
class GoferKeyChange < ApplicationRecord
  belongs_to :browser
  belongs_to :decider, class_name: "Principal"

  validates :key_name, presence: true
  validate :decider_is_human

  before_create { self.id ||= ULID.generate }

  scope :recent, -> { order(created_at: :desc) }

  private

  def decider_is_human
    errors.add(:decider, "must be a person") if decider && !decider.trusted?
  end
end
