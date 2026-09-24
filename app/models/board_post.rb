# One post on the household message board (SENTINEL.md, hob.board.read).
# thread_id/thread_slug/thread_topic are denormalized onto every post in a
# thread, same as message_nodes denormalizes realm from conversations —
# there is no separate threads table; the thread index groups these rows.
# Posts are immutable and append-only: whatever creates them (hob.board.post,
# a companion capability, still to be built) never updates or deletes one.
class BoardPost < ApplicationRecord
  belongs_to :sender_agent, class_name: "Principal"
  belongs_to :sender_principal, class_name: "Principal"

  validates :thread_id, :thread_slug, :thread_topic, :realm, :body, presence: true
  validate :links_are_a_list_of_strings
  validate :sender_shapes

  before_create { self.id ||= ULID.generate }

  scope :in_thread, ->(ref) { where(thread_id: ref).or(where(thread_slug: ref)) }

  private

  def links_are_a_list_of_strings
    errors.add(:links, "must be an array of strings") unless links.is_a?(Array) && links.all? { |l| l.is_a?(String) }
  end

  # A post is always from an agent, stamped with the person the agent spoke
  # for — the same shape as CalendarEvent's source_agent/owner.
  def sender_shapes
    errors.add(:sender_agent, "must be an agent") if sender_agent && !sender_agent.agent?
    errors.add(:sender_principal, "must not be an agent") if sender_principal&.agent?
  end
end
