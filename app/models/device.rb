# A phone running the companion app (clients/ios), registered by a person's
# key so hob can push to it when a petition or request needs them. See Push.
class Device < ApplicationRecord
  PLATFORMS = %w[ios].freeze
  ENVIRONMENTS = %w[sandbox production].freeze

  belongs_to :principal

  validates :platform, inclusion: { in: PLATFORMS }
  validates :environment, inclusion: { in: ENVIRONMENTS }
  validates :token, presence: true, uniqueness: true, format: { with: /\A[0-9a-f]{16,}\z/ }

  scope :of_people, -> { joins(:principal).where(principals: { kind: "human" }) }

  # Register (or re-register) a phone. The token is the identity: a phone
  # that reinstalls, or whose token Apple rotated, is a fresh row; the same
  # token from the same app is a refresh.
  def self.register!(principal:, token:, environment:, name: nil, app_version: nil, platform: "ios")
    device = find_or_initialize_by(token: token.to_s.downcase)
    device.assign_attributes(principal: principal, environment: environment, platform: platform,
                             name: name.presence, app_version: app_version.presence, last_seen_at: Time.current)
    device.save!
    device
  end

  def sandbox?
    environment == "sandbox"
  end

  def label
    name.presence || "#{principal.name}'s #{platform} device"
  end
end
