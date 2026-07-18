# Exactly what the model saw, hash-addressed. Written by the assembly
# pipeline on every turn; the inspector reads it back. (Column is `digest`
# because `hash` collides with Object#hash.)
class PromptSnapshot < ApplicationRecord
  self.primary_key = :digest

  belongs_to :conversation

  validates :assembled, presence: true

  def self.record!(conversation:, assembled:)
    digest = Digest::SHA256.hexdigest(JSON.generate(assembled))[0, 32]
    existing = find_by(digest: digest)
    return existing if existing

    create!(digest: digest, conversation_id: conversation.id, realm: conversation.realm,
            assembled: assembled, created_at: Time.current)
  end
end
