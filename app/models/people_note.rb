# What an agent or a person wrote about someone (PEOPLE.md): an opinion with
# a byline, not a fact. Append-only, attributed from the request, and
# realm-tagged at or above its person's realm.
class PeopleNote < ApplicationRecord
  BODY_LIMIT = 4000

  belongs_to :person, optional: true
  belongs_to :group, class_name: "PeopleGroup", optional: true
  belongs_to :author, class_name: "Principal"

  validates :body, presence: true, length: { maximum: BODY_LIMIT }
  validates :realm, presence: true

  before_create { self.id ||= ULID.generate }
  before_update { raise ActiveRecord::ReadOnlyRecord, "notes are append-only; write another" }

  def as_json(*)
    { "id" => id, "person" => person_id, "group" => group_id, "body" => body,
      "by" => { "principal" => author&.name, "surface" => surface }, "realm" => realm,
      "at" => created_at&.utc&.iso8601 }.compact
  end
end
