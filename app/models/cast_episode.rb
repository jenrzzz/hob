# One episode of a cast (CASTS.md): what the surface handed over, the script
# written from it, and where the finished audio is. `edition` is the
# surface's own name for it (a date, usually); a cast has one episode per
# edition.
class CastEpisode < ApplicationRecord
  belongs_to :cast

  STATUSES = %w[queued writing voicing mixing ready failed].freeze
  WORKING = %w[writing voicing mixing].freeze
  # A job that has said nothing for this long died with its container.
  STALE_AFTER = 30.minutes

  validates :edition, presence: true, length: { maximum: 80 }, uniqueness: { scope: :cast_id }
  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }

  before_create { self.id ||= ULID.generate }

  scope :ready, -> { where(status: "ready") }
  scope :newest, -> { order(Arel.sql("COALESCE(published_at, created_at) DESC")) }

  def ready? = status == "ready"
  def failed? = status == "failed"

  # Being made right now, as far as anyone can tell.
  def in_hand?
    (status == "queued" || WORKING.include?(status)) && updated_at > STALE_AFTER.ago
  end

  def audio
    audio_key.presence && AudioClip.lookup(realm: realm, key: audio_key)
  end

  def stories
    Array(source["stories"])
  end
end
