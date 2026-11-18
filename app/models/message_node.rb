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
  validates :content, presence: true, unless: -> { attachments.present? }
  validate :attachments_are_refs

  before_validation :compute_content_hash, on: :create

  # The conversation id is part of the address: nodes share one table, so two
  # conversations opening with the same words must not collide on the key.
  # Attachments are part of the address by digest (the bytes are in Blob),
  # and only when present, so every text node keeps the hash it always had.
  def self.hash_for(conversation_id:, role:, speaker:, content:, parent_hash:, attachments: [])
    parts = [ conversation_id, role, speaker.to_s, content, parent_hash ]
    parts << attachments.map { |a| a["digest"] || a[:digest] } if attachments.present?
    Digest::SHA256.hexdigest(JSON.generate(parts))[0, 32]
  end

  # Append under parent, deduping on content address (re-importing the same
  # turn twice is a no-op, per design).
  # attachments: [{ "type" => "image", "media_type", "digest", "size" }],
  # already stored in Blob (Attachments.ingest).
  def self.append!(conversation:, parent_hash:, role:, content:, speaker: nil, kind: "text", meta: {}, prompt_snapshot_hash: nil,
                   attachments: [])
    attachments = Array(attachments)
    hash = hash_for(conversation_id: conversation.id, role: role, speaker: speaker, content: content, parent_hash: parent_hash,
                    attachments: attachments)
    existing = conversation.message_nodes.find_by(content_hash: hash)
    return existing if existing

    conversation.message_nodes.create!(
      content_hash: hash, parent_hash: parent_hash, realm: conversation.realm,
      role: role, speaker: speaker, kind: kind, content: content, meta: meta,
      prompt_snapshot_hash: prompt_snapshot_hash, created_at: Time.current, attachments: attachments
    )
  end

  def tool_call?
    kind == "tool_call"
  end

  def tool_result?
    kind == "tool_result"
  end

  # A tool_call node's content is the call itself: { id, name, arguments }.
  def tool_call
    return nil unless tool_call?

    JSON.parse(content)
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
      conversation_id: conversation_id, role: role, speaker: speaker, content: content, parent_hash: parent_hash,
      attachments: attachments
    )
  end

  def attachments_are_refs
    return if attachments.all? { |a| a.is_a?(Hash) && a["digest"].to_s.start_with?("sha256:") && !a.key?("data") }

    errors.add(:attachments, "hold digests, never bytes")
  end
end
