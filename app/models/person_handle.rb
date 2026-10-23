# An address that reaches a Person (PEOPLE.md): a phone number, an email
# address, or something else with a label. Normalized (People::Handles) so
# the same number written two ways is one handle, and unique: one handle is
# one person, and two records become one only by a merge a person approves.
# `realm` is the person's, copied for RLS.
class PersonHandle < ApplicationRecord
  KINDS = %w[phone email other].freeze
  LABEL_LIMIT = 100

  belongs_to :person

  validates :kind, inclusion: { in: KINDS }
  validates :address, presence: true, length: { maximum: 320 }
  validates :label, length: { maximum: LABEL_LIMIT }, allow_nil: true
  validates :realm, presence: true

  before_create { self.id ||= ULID.generate }

  def as_json(*)
    { "kind" => kind, "address" => address, "label" => label, "opens_loops" => opens_loops }.compact
  end
end
