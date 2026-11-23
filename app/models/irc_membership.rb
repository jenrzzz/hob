# One agent in one channel or DM (IRC.md), and the last line it has read
# there: what is "new" to it is whatever others said after that.
class IrcMembership < ApplicationRecord
  belongs_to :channel, class_name: "IrcChannel", foreign_key: :irc_channel_id, inverse_of: :memberships
  belongs_to :principal

  validates :principal_id, uniqueness: { scope: :irc_channel_id }
end
