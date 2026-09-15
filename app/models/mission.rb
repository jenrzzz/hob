# Work addressed to a principal that polls for it (SENTINEL.md): the passive
# queue / active worker protocol the GPU workers already use, generalized.
# An agent that can only make outbound connections leases the next mission,
# heartbeats while it works, and completes or fails it with a result. A
# lease that expires goes back to the queue.
class Mission < ApplicationRecord
  STATUSES = %w[queued leased completed failed cancelled].freeze
  DEFAULT_LEASE = 300 # seconds
  MAX_LEASE = 3600

  belongs_to :assignee, class_name: "Principal"
  belongs_to :created_by, class_name: "Principal", optional: true

  validates :title, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :realm, presence: true

  before_create { self.id ||= ULID.generate }

  scope :queued, -> { where(status: "queued") }
  scope :open, -> { where(status: %w[queued leased]) }
  scope :for, ->(principal) { where(assignee: principal) }

  def sentinel_request
    sentinel_request_id && SentinelRequest.find_by(id: sentinel_request_id)
  end

  # Lease the next queued mission for `principal`, highest priority first,
  # oldest first. Expired leases are requeued on the way in. Returns nil when
  # the queue is empty. SKIP LOCKED keeps two pollers from taking one mission.
  def self.lease_next!(principal, lease: DEFAULT_LEASE)
    lease = lease.to_i.clamp(1, MAX_LEASE)
    transaction do
      requeue_expired!(principal)
      candidate = queued.for(principal).order(priority: :desc, created_at: :asc).lock("FOR UPDATE SKIP LOCKED").first
      next nil unless candidate

      candidate.update!(status: "leased", lease_token: SecureRandom.hex(16), leased_at: Time.current,
                        lease_expires_at: lease.seconds.from_now, attempts: candidate.attempts + 1)
      candidate
    end
  end

  def self.requeue_expired!(principal = nil)
    scope = where(status: "leased").where(lease_expires_at: ...Time.current)
    scope = scope.for(principal) if principal
    scope.update_all(status: "queued", lease_token: nil, leased_at: nil, lease_expires_at: nil)
  end

  def leased?
    status == "leased"
  end

  def settled?
    %w[completed failed cancelled].include?(status)
  end

  # The holder of the lease proves it with the token; a worker whose lease
  # expired and was re-leased elsewhere can no longer complete it.
  def held_by?(token)
    leased? && lease_token.present? && ActiveSupport::SecurityUtils.secure_compare(lease_token, token.to_s)
  end

  def heartbeat!(lease: DEFAULT_LEASE)
    update!(lease_expires_at: lease.to_i.clamp(1, MAX_LEASE).seconds.from_now)
  end

  def complete!(result)
    update!(status: "completed", result: result, lease_token: nil, error: nil)
    sentinel_request&.finish!(result)
  end

  def fail!(message)
    update!(status: "failed", error: message.to_s.truncate(2000), lease_token: nil)
    sentinel_request&.fail!("mission #{id} failed: #{message}")
  end

  def cancel!
    update!(status: "cancelled", lease_token: nil)
    sentinel_request&.fail!("mission #{id} was cancelled")
  end
end
