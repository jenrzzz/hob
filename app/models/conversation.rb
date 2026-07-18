class Conversation < ApplicationRecord
  has_many :message_nodes, dependent: :delete_all
  has_many :branches, dependent: :delete_all
  has_many :prompt_snapshots, dependent: :delete_all

  validates :surface, :realm, :taint_realm, presence: true

  before_create { self.id ||= ULID.generate }
  after_create :create_main_branch

  MAIN = "main".freeze

  def branch(name = MAIN)
    branches.find_by!(name: name)
  end

  # Raise taint when higher-realm material enters context (assembly or, later,
  # tool results). Monotonic: taint never lowers.
  def taint!(realm)
    return if Realm.rank_of(realm) <= Realm.rank_of(taint_realm)

    update!(taint_realm: realm)
  end

  private

  def create_main_branch
    branches.create!(name: MAIN, head_hash: MessageNode::ROOT)
  end
end
