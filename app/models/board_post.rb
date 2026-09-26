# One post on the household message board (SENTINEL.md, hob.board.read and
# hob.board.post). thread_id/thread_slug/thread_topic are denormalized onto
# every post in a thread, same as message_nodes denormalizes realm from
# conversations — there is no separate threads table; the thread index
# groups these rows. Posts are immutable and append-only: hob.board.post
# never updates or deletes one, and no such path is exposed.
class BoardPost < ApplicationRecord
  belongs_to :sender_agent, class_name: "Principal"

  MAX_LINKS = 5

  validates :thread_id, :thread_slug, :thread_topic, :realm, :body, :surface, presence: true
  validates :thread_topic, length: { maximum: 200 }
  validates :body, length: { maximum: 4000 }
  validate :links_are_http_urls
  validate :sender_agent_is_an_agent

  before_create { self.id ||= ULID.generate }

  scope :in_thread, ->(ref) { where(thread_id: ref).or(where(thread_slug: ref)) }

  private

  def links_are_http_urls
    return errors.add(:links, "must be an array of at most #{MAX_LINKS} http(s) URLs") unless links.is_a?(Array) && links.size <= MAX_LINKS

    errors.add(:links, "must be an array of http(s) URLs") unless links.all? { |l| l.is_a?(String) && l.match?(%r{\Ahttps?://}) }
  end

  def sender_agent_is_an_agent
    errors.add(:sender_agent, "must be an agent") if sender_agent && !sender_agent.agent?
  end
end
