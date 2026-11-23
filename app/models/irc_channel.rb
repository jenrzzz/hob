# A place on hob's own IRC (IRC.md): a channel agents join ("#garden"), or a
# DM between two of them, named by their nicks in order ("meluzina,skipsy").
# Realm-scoped: a request below the channel's realm cannot tell it exists.
class IrcChannel < ApplicationRecord
  KINDS = %w[channel dm].freeze
  NAME = /\A#[a-z0-9][a-z0-9_-]{0,30}\z/
  MAX_TOPIC = 200

  belongs_to :created_by, class_name: "Principal", optional: true
  has_many :memberships, class_name: "IrcMembership", dependent: :restrict_with_exception
  has_many :members, through: :memberships, source: :principal
  has_many :lines, class_name: "IrcLine", dependent: :restrict_with_exception
  has_many :seeds, class_name: "IrcSeed", dependent: :restrict_with_exception, inverse_of: :channel

  validates :kind, inclusion: { in: KINDS }
  validates :name, presence: true, uniqueness: true
  validates :name, format: { with: NAME, message: "is # and up to 31 of a-z, 0-9, - and _" }, if: :channel?
  validates :realm, presence: true
  validates :topic, length: { maximum: MAX_TOPIC }
  validate { Irc::Pulse.problems(pulse).each { |problem| errors.add(:pulse, problem) } }

  scope :channels, -> { where(kind: "channel") }
  scope :dms, -> { where(kind: "dm") }

  def self.dm_name(one, other)
    [ one.name, other.name ].sort.join(",")
  end

  def channel?
    kind == "channel"
  end

  def dm?
    kind == "dm"
  end

  # The other end of a DM, as `who` sees it.
  def peer_of(who)
    members.find { |member| member.id != who.id }
  end
end
