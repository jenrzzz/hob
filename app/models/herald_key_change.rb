# One edit to a herald key's permissions or scope (TEXTS.md), from
# HeraldKeysController. Unlike gofer, herald can say what a key is, so
# `key_before` is what herald answered just before the change, not a guess.
class HeraldKeyChange < ApplicationRecord
  belongs_to :text_backend
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
