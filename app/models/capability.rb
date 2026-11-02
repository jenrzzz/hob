# Something an agent can ask the sentinel for. Three venues:
#   native   hob runs it in-process (config.handler names a Sentinel::Native class)
#   webhook  hob POSTs a signed request to a surface (config.url, config.secret)
#   poll     hob queues a mission for a principal that polls for work (config.assignee)
# `realm` is the clearance an agent needs to ask; `kind` says whether the
# capability reads or acts, which the reviewer and listings care about.
# config.requires_person marks one only a person may approve.
#
# A webhook capability is the plugin venue, v0 (PLUGINS.md): the app that
# serves the manifest owns the implementation. One the app added on its own
# (SurfaceCapabilities#refresh, no person running the command) lands
# unaccepted and disabled: `accepted_at` is nil, no rule reaches it, not even
# a wildcard, and no petition waiting on its name is granted, until a person
# accepts it (#accept!) and confirms or changes the realm and kind it
# proposed. Everything else (native handlers, by-hand registration, a
# person's own POST) is accepted as it is created, since a person put it there.
#
# A webhook row a surface registered belongs to its Plugin installation
# (PLUGINS.md, Phase 1). Whether a caller may reach it also depends on the
# installation: not while it is quarantined, and, for a personal one, only
# by its owner (#unavailable_to, enforced in listings, at the gate, and
# again at delivery).
class Capability < ApplicationRecord
  class Error < StandardError; end

  NAME_FORMAT = /\A[a-z0-9]+(?:[._-][a-z0-9]+)*\z/
  KINDS = %w[read act].freeze
  VENUES = %w[native webhook poll].freeze

  belongs_to :accepted_by, class_name: "Principal", optional: true
  belongs_to :plugin, optional: true
  has_many :sentinel_requests, dependent: :restrict_with_exception

  # Accepted unless whoever creates it says otherwise (accepted_at: nil).
  attribute :accepted_at, :datetime, default: -> { Time.current }

  validates :name, presence: true, uniqueness: true, format: { with: NAME_FORMAT }
  validates :description, presence: true
  validates :kind, inclusion: { in: KINDS }
  validates :venue, inclusion: { in: VENUES }
  validates :realm, presence: true
  validate :realm_known
  validate :venue_config
  validate :accepted_before_enabled

  scope :enabled, -> { where(enabled: true) }
  scope :unaccepted, -> { where(accepted_at: nil) }
  # What may be shown to `caller` as something to ask for: enabled, and not
  # from an installation it may not reach (Plugin#unavailable_to, in SQL).
  scope :offered_to, lambda { |caller|
    person = caller && !caller.agent? ? caller.id : nil
    enabled.joins("LEFT JOIN plugins ON plugins.id = capabilities.plugin_id " \
                  "LEFT JOIN principals plugin_principals ON plugin_principals.id = plugins.principal_id")
           .where("capabilities.plugin_id IS NULL OR (plugin_principals.capabilities_frozen_at IS NULL " \
                  "AND (plugins.owner_id IS NULL OR plugins.owner_id = ?))", person)
  }

  # A capability that petitions were waiting on has arrived (a merged forge
  # PR synced at boot, or a person registering a surface): grant them. One a
  # surface proposed on its own waits for #accept!.
  after_create { Petition.fulfil!(self) if accepted? }

  def accepted?
    accepted_at.present?
  end

  # A person has looked at a capability a surface proposed: it takes the
  # realm and kind they confirmed (the proposal's, unless they changed it),
  # is enabled, and the petitions waiting on it are granted.
  def accept!(by: nil, realm: nil, kind: nil)
    raise Error, "#{name} is already accepted" if accepted?
    raise Error, "only a person accepts a capability" if by && !by.trusted?

    transaction do
      update!(accepted_at: Time.current, accepted_by: by, enabled: true,
              realm: realm.presence || self.realm, kind: kind.presence || self.kind)
      Petition.fulfil!(self)
    end
    self
  end

  # The rules that will reach it once accepted, wildcards included: what a
  # person is agreeing to by accepting (PLUGINS.md, sections 5 and 7).
  def reaching_rules
    SentinelPolicy.includes(:principal).select { |rule| rule.matches?(name) }
                  .sort_by { |rule| [ rule.principal&.name.to_s, -rule.specificity ] }
  end

  # Petitions that accepting it will grant.
  def waiting_petitions
    Petition.where(status: %w[proposed building], capability_name: name).includes(:principal)
  end

  # -> why `caller` may not reach it, whatever a rule says, or nil.
  def unavailable_to(caller)
    plugin&.unavailable_to(caller)
  end

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

  # Only a person may approve a request for it (RECORDS.md): whatever rule
  # covers it, `allow` and `review` are taken as `confirm` (Sentinel::Gate),
  # and a rule naming it exactly cannot say otherwise (SentinelPolicy).
  def requires_person?
    config["requires_person"] == true
  end

  private

  def realm_known
    Realm.rank_of(realm) if realm.present?
  rescue ArgumentError => e
    errors.add(:realm, e.message)
  end

  def accepted_before_enabled
    errors.add(:enabled, "can't be on until a person accepts #{name}") if enabled && !accepted?
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
