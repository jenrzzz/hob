# Something worth reacting to, waiting in a channel's tray for its host to
# drop in (Irc::Pulse). Mined by a surface (kat: an archive stretch, a story's
# best lines), kept at the channel's realm, taken once. One meant for an
# agent came from her own threads, and is hers alone to take.
class IrcSeed < ApplicationRecord
  MAX_BODY = 4_000
  MAX_TITLE = 120
  KIND = /\A[a-z][a-z0-9_-]{0,30}\z/
  PREVIEW = 140

  belongs_to :channel, class_name: "IrcChannel", foreign_key: :irc_channel_id, inverse_of: :seeds
  belongs_to :taken_by, class_name: "Principal", optional: true
  belongs_to :meant_for, class_name: "Principal", optional: true

  validates :kind, format: { with: KIND }
  validates :body, presence: true, length: { maximum: MAX_BODY }
  validates :title, length: { maximum: MAX_TITLE }
  validates :realm, presence: true

  before_validation { self.realm = channel&.realm if realm.blank? }

  scope :waiting, -> { where(taken_at: nil) }
  # What `agent` may take: hers, and anyone's. Hers first.
  scope :open_to, ->(agent) { where(meant_for_id: [ nil, agent&.id ]).order(Arel.sql("meant_for_id IS NULL")) }

  def preview
    (title.presence || body).squish.truncate(PREVIEW)
  end
end
