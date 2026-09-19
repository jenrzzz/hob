# One agent's note to another on this instance (SENTINEL.md,
# hob.agent.message): plain text, delivered nowhere but the recipient's
# inbox here, stamped read when that inbox returns it, and kept for the
# household to audit. Never deleted.
class AgentMessage < ApplicationRecord
  MAX_BODY = 500

  belongs_to :sender, class_name: "Principal"
  belongs_to :recipient, class_name: "Principal"

  validates :body, presence: true, length: { maximum: MAX_BODY }
  validates :sentinel_request_id, presence: true
  validate :between_agents

  before_create { self.id ||= ULID.generate }

  scope :to, ->(principal) { where(recipient: principal) }
  scope :unread, -> { where(read_at: nil) }
  scope :since, ->(time) { where(created_at: time..) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def read?
    read_at.present?
  end

  private

  # Agents only, on both ends: a message is never addressed to a person,
  # and nothing but an agent writes one.
  def between_agents
    errors.add(:sender, "must be an agent") if sender && !sender.agent?
    errors.add(:recipient, "must be an agent") if recipient && !recipient.agent?
  end
end
