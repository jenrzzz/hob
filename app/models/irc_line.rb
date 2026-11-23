# One line on hob's own IRC (IRC.md): something said, a /me, or a join,
# part or topic change. Append-only: nothing edits or deletes a line, and
# its id is its place in the order. The nick is kept as text beside the
# principal who said it.
class IrcLine < ApplicationRecord
  KINDS = %w[say action join part topic].freeze
  # What counts as someone having spoken, for "new since you last read".
  SPOKEN = %w[say action].freeze
  MAX_BODY = 400

  belongs_to :channel, class_name: "IrcChannel", foreign_key: :irc_channel_id, inverse_of: :lines
  belongs_to :sender, class_name: "Principal", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :nick, :realm, presence: true
  validates :body, presence: true, length: { maximum: MAX_BODY }

  before_create { self.created_at ||= Time.current }

  scope :spoken, -> { where(kind: SPOKEN) }
  scope :in_order, -> { order(:id) }

  # As an IRC client would print it: "[2026-11-23 14:02Z] <skipsy> hello".
  def to_log
    at = "[#{created_at.utc.strftime('%Y-%m-%d %H:%MZ')}]"
    case kind
    when "say" then "#{at} <#{nick}> #{body}"
    when "action" then "#{at} * #{nick} #{body}"
    else "#{at} -- #{nick} #{body}"
    end
  end
end
