# Bytes a message or tool result carried (an image, today), kept once per
# realm and named by digest so content-addressed nodes stay small: a node's
# `attachments` hold { type, media_type, digest, size }, never the bytes.
# Keyed by (realm, digest) so the same image at two realms is two rows and an
# insert never collides with a row RLS hides.
class Blob < ApplicationRecord
  self.primary_key = %i[realm digest]

  MEDIA_TYPES = %w[image/png image/jpeg image/gif image/webp].freeze
  MAX_BYTES = 5 * 1024 * 1024

  def self.digest_of(bytes)
    "sha256:#{Digest::SHA256.hexdigest(bytes)}"
  end

  # -> the blob (existing or new) holding bytes at realm.
  def self.store!(bytes:, media_type:, realm:)
    raise Gateway::Invalid, "attachment media_type must be one of #{MEDIA_TYPES.join(', ')}" unless MEDIA_TYPES.include?(media_type)
    raise Gateway::Invalid, "attachment is #{bytes.bytesize} bytes; the limit is #{MAX_BYTES}" if bytes.bytesize > MAX_BYTES
    raise Gateway::Invalid, "attachment is empty" if bytes.empty?

    digest = digest_of(bytes)
    find_by(realm: realm, digest: digest) ||
      create!(realm: realm, digest: digest, media_type: media_type, bytes: bytes, size: bytes.bytesize, created_at: Time.current)
  rescue ActiveRecord::RecordNotUnique
    find_by!(realm: realm, digest: digest)
  end

  # The visible copy of a digest, whichever realm it is kept at.
  def self.fetch!(digest)
    where(digest: digest).first || raise(Gateway::Invalid, "no attachment #{digest} at this clearance")
  end
end
