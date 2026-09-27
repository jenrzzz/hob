class ApiKey < ApplicationRecord
  belongs_to :principal

  validates :token_digest, presence: true, uniqueness: true
  validates :surface, :default_clearance, presence: true

  # Raw tokens are shown once at creation and stored only as a digest.
  def self.issue!(principal:, surface:, default_clearance:)
    token = "hob_#{SecureRandom.hex(24)}"
    create!(principal: principal, surface: surface, default_clearance: default_clearance,
            token_digest: digest(token))
    token
  end

  # A new key for the principal's surface, then its older keys for that
  # surface go. Returns the raw token and how many were revoked.
  def self.rotate!(principal:, surface:, default_clearance:)
    token = issue!(principal: principal, surface: surface, default_clearance: default_clearance)
    rotated = principal.api_keys.where(surface: surface).where.not(token_digest: digest(token)).destroy_all.size
    [ token, rotated ]
  end

  def self.authenticate(token)
    return nil if token.blank?

    find_by(token_digest: digest(token))
  end

  def self.digest(token)
    Digest::SHA256.hexdigest(token)
  end

  # request clearance = min(key default, principal grant) by realm rank
  def clearance
    [ default_clearance, principal.max_clearance ].min_by { |slug| Realm.rank_of(slug) }
  end
end
