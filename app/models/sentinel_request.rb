# One ask by an agent, its decision, and what came of it. Never deleted:
# this table is the sentinel's audit log.
#
#   status   pending    waiting for a person (decision: escalate or effect confirm)
#            executing  approved; a poll-venue mission is doing the work
#            completed  approved and done; `result` holds the outcome
#            failed     approved but execution failed; `error` says why
#            denied     refused by policy, limit, constraint, realm, reviewer, or a person
class SentinelRequest < ApplicationRecord
  STATUSES = %w[pending executing completed failed denied].freeze
  DECISIONS = %w[allow deny escalate].freeze
  DECIDERS = %w[policy limit constraint realm reviewer human].freeze

  belongs_to :principal
  belongs_to :capability
  belongs_to :decider, class_name: "Principal", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :decision, inclusion: { in: DECISIONS }, allow_nil: true
  validates :decided_by, inclusion: { in: DECIDERS }, allow_nil: true
  validates :realm, presence: true

  before_create { self.id ||= ULID.generate }

  scope :pending, -> { where(status: "pending") }
  scope :recent, -> { order(created_at: :desc) }
  scope :since, ->(time) { where(created_at: time..) }
  # Requests that consumed the agent's allowance: anything not refused outright.
  scope :counted, -> { where.not(status: "denied") }

  def pending?
    status == "pending"
  end

  def settled?
    %w[completed failed denied].include?(status)
  end

  def mission
    mission_id && Mission.find_by(id: mission_id)
  end

  def ref
    "sentinel/#{id}"
  end

  def decide!(decision:, decided_by:, rationale:, decider: nil, review: nil)
    attrs = { decision: decision, decided_by: decided_by, rationale: rationale, decider: decider, decided_at: Time.current }
    attrs[:review] = review if review
    attrs[:status] = decision == "deny" ? "denied" : "pending"
    update!(attrs)
  end

  def finish!(result)
    update!(status: "completed", result: result, executed_at: Time.current, error: nil)
  end

  def fail!(message)
    update!(status: "failed", error: message.to_s.truncate(2000), executed_at: Time.current)
  end
end
