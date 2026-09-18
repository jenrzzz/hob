# An agent asking for a capability it does not have (SENTINEL.md, "Petitions
# and the forge"). Never deleted: with sentinel_requests, the audit trail.
#
#   status   pending    a person has to look (referred, or the charter says confirm)
#            granted    a policy rule now lets the agent ask for `capability_name`
#            building   the forge is implementing it; `mission_id` is the build
#            proposed   a pull request is open; granted once it is merged and deployed
#            denied     refused; `decided_by` says by what
#            failed     the build failed; a person may re-dispatch or deny
#
#   action   grant | build | refer | deny — what the steward (or a person) chose
class Petition < ApplicationRecord
  STATUSES = %w[pending granted building proposed denied failed].freeze
  ACTIONS = %w[grant build refer deny].freeze
  DECIDERS = %w[policy limit steward human].freeze
  GRANTABLE_EFFECTS = %w[allow review confirm].freeze

  belongs_to :principal
  belongs_to :decider, class_name: "Principal", optional: true
  belongs_to :sentinel_policy, optional: true

  validates :want, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :action, inclusion: { in: ACTIONS }, allow_nil: true
  validates :decided_by, inclusion: { in: DECIDERS }, allow_nil: true
  validates :effect, inclusion: { in: GRANTABLE_EFFECTS }, allow_nil: true
  validates :capability_name, format: { with: Capability::NAME_FORMAT }, allow_nil: true
  validates :realm, presence: true

  before_create { self.id ||= ULID.generate }

  scope :pending, -> { where(status: "pending") }
  scope :proposed, -> { where(status: "proposed") }
  scope :open, -> { where(status: %w[pending building proposed]) }
  scope :recent, -> { order(created_at: :desc) }
  scope :since, ->(time) { where(created_at: time..) }
  # Petitions that consumed the agent's allowance: anything not refused outright.
  scope :counted, -> { where.not(status: "denied") }

  def pending?
    status == "pending"
  end

  def settled?
    %w[granted denied].include?(status)
  end

  def mission
    mission_id && Mission.find_by(id: mission_id)
  end

  def ref
    "petition/#{id}"
  end

  def capability
    capability_name && Capability.find_by(name: capability_name)
  end

  # Record who decided what; the status follows the action. `grant` and
  # `build` are carried out by Sentinel::Steward.apply!, which calls the
  # bang methods below once the side effects exist.
  def decide!(action:, decided_by:, rationale:, decider: nil, review: nil, effect: nil, capability_name: nil, spec: nil)
    attrs = { action: action, decided_by: decided_by, rationale: rationale, decider: decider, decided_at: Time.current }
    attrs[:review] = review if review
    attrs[:effect] = effect if effect
    attrs[:capability_name] = capability_name if capability_name
    attrs[:spec] = spec if spec
    attrs[:status] = case action
    when "deny" then "denied"
    else "pending"
    end
    attrs[:settled_at] = Time.current if action == "deny"
    update!(attrs)
  end

  def grant!(policy)
    update!(status: "granted", sentinel_policy: policy, effect: policy.effect, capability_name: policy.capability,
            settled_at: Time.current, error: nil)
  end

  def build!(mission)
    update!(status: "building", mission_id: mission.id, error: nil)
  end

  def propose!(pull_request)
    update!(status: "proposed", pull_request: pull_request.presence)
  end

  def fail!(message)
    update!(status: "failed", error: message.to_s.truncate(2000))
  end

  # A capability appeared (merged, deployed, synced): every proposal waiting
  # on it becomes the grant it was promised. Called from Capability.
  def self.fulfil!(capability)
    Clearance.with("intimate") do
      where(status: %w[proposed building], capability_name: capability.name).find_each do |petition|
        rule = SentinelPolicy.find_or_initialize_by(principal: petition.principal, capability: capability.name)
        rule.effect = petition.effect || "confirm"
        rule.constraints = petition.spec["constraints"] if petition.spec["constraints"].is_a?(Hash) && rule.new_record?
        rule.limits = petition.spec["limits"] if petition.spec["limits"].is_a?(Hash) && rule.new_record?
        rule.guidance = petition.spec["guidance"] if petition.spec["guidance"].present? && rule.new_record?
        rule.save!
        petition.grant!(rule)
      end
    end
  end
end
