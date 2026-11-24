# Audio hob made or paid for (CASTS.md, "Voice"): a stretch of dialogue, a
# stinger, a theme, a finished episode. Kept once per realm and named by a
# digest of what was asked for, so asking again costs nothing. Keyed by
# (realm, key) like Blob, so an insert never collides with a row RLS hides.
class AudioClip < ApplicationRecord
  self.primary_key = %i[realm key]

  KINDS = %w[dialogue sound music episode].freeze

  validates :kind, inclusion: { in: KINDS }

  # A clip's name: what would make it sound different, and nothing else.
  def self.key_for(*parts)
    Digest::SHA256.hexdigest(JSON.generate(parts))
  end

  def self.lookup(realm:, key:)
    find_by(realm: realm, key: key)
  end

  def self.store!(realm:, key:, kind:, bytes:, meta: {}, media_type: "audio/mpeg")
    raise ArgumentError, "an audio clip needs bytes" if bytes.blank?

    lookup(realm: realm, key: key) ||
      create!(realm: realm, key: key, kind: kind, bytes: bytes, size: bytes.bytesize, meta: meta,
              media_type: media_type, created_at: Time.current)
  rescue ActiveRecord::RecordNotUnique
    lookup(realm: realm, key: key)
  end
end
