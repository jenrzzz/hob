# Immutable, content-addressed chat nodes — git for chat. Swipes are siblings
# under one parent; branches are named refs; nothing is ever destroyed.
class MessageNode < ApplicationRecord
  self.primary_key = :content_hash

  ROOT = "root".freeze # sentinel parent_hash for first nodes; not a row
  ROLES = %w[user assistant system event].freeze
  KINDS = %w[text tool_call tool_result event].freeze

  belongs_to :conversation

  validates :role, inclusion: { in: ROLES }
  validates :kind, inclusion: { in: KINDS }
  validates :content, presence: true

  before_validation :compute_content_hash, on: :create

  def self.hash_for(role:, speaker:, content:, parent_hash:)
    Digest::SHA256.hexdigest(JSON.generate([ role, speaker.to_s, content, parent_hash ]))[0, 32]
  end

  # Append under parent, deduping on content address (re-importing the same
  # turn twice is a no-op, per design).
  def self.append!(conversation:, parent_hash:, role:, content:, speaker: nil, kind: "text", meta: {}, prompt_snapshot_hash: nil)
    hash = hash_for(role: role, speaker: speaker, content: content, parent_hash: parent_hash)
    existing = conversation.message_nodes.find_by(content_hash: hash)
    return existing if existing

    conversation.message_nodes.create!(
      content_hash: hash, parent_hash: parent_hash, realm: conversation.realm,
      role: role, speaker: speaker, kind: kind, content: content, meta: meta,
      prompt_snapshot_hash: prompt_snapshot_hash, created_at: Time.current
    )
  end

  def parent
    return nil if parent_hash == ROOT

    conversation.message_nodes.find_by(content_hash: parent_hash)
  end

  # Swipes: nodes sharing this node's parent, in creation order.
  def siblings
    conversation.message_nodes.where(parent_hash: parent_hash).order(:created_at)
  end

  # Walk head -> root. Returns newest-first.
  def ancestry
    nodes = conversation.message_nodes.index_by(&:content_hash)
    chain = []
    cursor = self
    while cursor
      chain << cursor
      cursor = cursor.parent_hash == ROOT ? nil : nodes[cursor.parent_hash]
    end
    chain
  end

  private

  def compute_content_hash
    self.content_hash ||= self.class.hash_for(
      role: role, speaker: speaker, content: content, parent_hash: parent_hash
    )
  end
end
