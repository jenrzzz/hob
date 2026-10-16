# Something people are in (PEOPLE.md): a circle someone named ("family"), or
# a group chat hob saw (chat_ref, text:<chat id>). A person's circles are the
# names of their groups. A loop, an event, or a note can hang off a group.
class PeopleGroup < ApplicationRecord
  NAME_LIMIT = 200

  belongs_to :principal, optional: true
  has_many :memberships, class_name: "GroupMembership", foreign_key: :group_id, inverse_of: :group, dependent: :delete_all
  has_many :people, through: :memberships

  validates :name, presence: true, length: { maximum: NAME_LIMIT }
  validates :realm, presence: true

  before_create { self.id ||= ULID.generate }

  def ref
    "group:#{id}"
  end

  def as_json(*)
    { "id" => id, "ref" => ref, "name" => name, "chat" => chat_ref&.delete_prefix("text:"), "realm" => realm,
      "whose" => principal&.name, "members" => people.select { |p| !p.merged? }.map { |p| { "id" => p.id, "display_name" => p.display_name } } }
  end
end
