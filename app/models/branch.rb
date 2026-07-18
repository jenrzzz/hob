# A named ref pointing at a leaf hash. Regenerate/edit = new node + ref move.
class Branch < ApplicationRecord
  belongs_to :conversation

  validates :name, presence: true, uniqueness: { scope: :conversation_id }
  validates :head_hash, presence: true

  def head
    return nil if head_hash == MessageNode::ROOT

    conversation.message_nodes.find_by(content_hash: head_hash)
  end

  def advance!(node)
    update!(head_hash: node.content_hash)
  end

  # Chronological (oldest-first) messages on this branch.
  def timeline
    head&.ancestry&.reverse || []
  end
end
