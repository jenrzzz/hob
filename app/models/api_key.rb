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
