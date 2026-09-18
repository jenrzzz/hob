# Something an agent can ask the sentinel for. Three venues:
#   native   hob runs it in-process (config.handler names a Sentinel::Native class)
#   webhook  hob POSTs a signed request to a surface (config.url, config.secret)
#   poll     hob queues a mission for a principal that polls for work (config.assignee)
# `realm` is the clearance an agent needs to ask; `kind` says whether the
# capability reads or acts, which the reviewer and listings care about.
class Capability < ApplicationRecord
  NAME_FORMAT = /\A[a-z0-9]+(?:[._-][a-z0-9]+)*\z/
  KINDS = %w[read act].freeze
  VENUES = %w[native webhook poll].freeze

  has_many :sentinel_requests, dependent: :restrict_with_exception

  validates :name, presence: true, uniqueness: true, format: { with: NAME_FORMAT }
  validates :description, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :venue, inclusion: { in: VENUES }
  validates :realm, presence: true
  validate :realm_known
  validate :venue_config

  scope :enabled, -> { where(enabled: true) }

  # A capability that petitions were waiting on has arrived (a merged forge
  # PR synced at boot, or a surface registering one): grant them.
  after_create { Petition.fulfil!(self) }

  def native?
    venue == "native"
  end

  def handler
    return nil unless native?

    Sentinel::Native.handler(config["handler"])
  end

  def assignee
    return nil unless venue == "poll"

    Principal.find_by(name: config["assignee"])
  end

  def realm_rank
    Realm.rank_of(realm)
  end

  private

  def realm_known
    Realm.rank_of(realm) if realm.present?
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def venue_config
    case venue
    when "native"
      errors.add(:config, "handler #{config['handler'].inspect} is not a Sentinel::Native handler") if Sentinel::Native.handler(config["handler"]).nil?
    when "webhook"
      errors.add(:config, "webhook needs a url") if config["url"].blank?
      errors.add(:config, "webhook needs a secret") if config["secret"].blank?
    when "poll"
      errors.add(:config, "poll needs an assignee principal") if config["assignee"].blank? || Principal.find_by(name: config["assignee"]).nil?
    end
  end
end
