# A GitHub repo that is one agent's own workshop (CODE.md): where Claude
# Code, on the forge, writes what the agent commissions. The agent never
# holds a credential for it; the forge's sandbox does, scoped to this repo.
#
# `realm` is the realm of what is in the repo, the agent's briefs included.
# RLS hides the row from a request below it. `agent` is whose it is: that
# agent, and people, reach it, and nobody else (Commissions.repos).
class CodeRepo < ApplicationRecord
  NAME_FORMAT = TodoBackend::NAME_FORMAT
  REPO_FORMAT = %r{\A[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*\z} # Forge::Commission::REPO, which the app does not load

  belongs_to :principal
  belongs_to :agent, class_name: "Principal"

  validates :name, presence: true, uniqueness: true, format: { with: NAME_FORMAT }
  validates :repo, presence: true, format: { with: REPO_FORMAT, message: "is owner/name on GitHub" }
  validates :realm, presence: true
  validates :about, length: { maximum: 500 }
  validate :realm_known
  validate :owned_by_a_person
  validate :kept_for_an_agent

  before_create { self.id ||= ULID.generate }

  scope :enabled, -> { where(enabled: true) }

  def as_json(*)
    { "id" => id, "name" => name, "repo" => repo, "about" => about, "owner" => principal&.name, "agent" => agent&.name,
      "realm" => realm, "enabled" => enabled, "created_at" => created_at, "updated_at" => updated_at }
  end

  private

  def realm_known
    Realm.rank_of(realm) if realm.present?
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def owned_by_a_person
    errors.add(:principal, "must be a person: somebody answers for a repo") if principal && !principal.trusted?
  end

  def kept_for_an_agent
    errors.add(:agent, "must be an agent: #{agent.name} is a #{agent.kind}") if agent && !agent.agent?
  end
end
