# A session an agent (or a person) has open on one of the household's
# consoles (KVM.md), for a stated goal. The row is the record of the
# session: who, what for, how many steps, how it ended. Each step is also a
# sentinel request, with its arguments and the frame's size.
#
# The screen itself is never stored, here or anywhere: the bridge holds the
# connection and every step answers with a fresh frame that goes to the
# caller and nowhere else. `remote_id` is the bridge's name for the session.
class ConsoleSession < ApplicationRecord
  STATUSES = %w[open closed expired lost].freeze
  MAX_STEPS = 500
  MIN_TTL = 30
  MAX_TTL = 900
  DEFAULT_TTL = 300
  MAX_LIFE = 30.minutes

  belongs_to :console
  belongs_to :principal

  validates :goal, presence: true
  validates :remote_id, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :ttl, numericality: { only_integer: true, in: MIN_TTL..MAX_TTL }

  before_create { self.id ||= ULID.generate }
  before_validation { self.expires_at ||= deadline_after(Time.current) if ttl }

  scope :open, -> { where(status: "open") }
  scope :owned_by, ->(principal) { where(principal: principal) }
  scope :overdue, ->(now = Time.current) { open.where(expires_at: ...now) }

  def open?
    status == "open"
  end

  # Past its idle deadline, or its whole life.
  def overdue?(now = Time.current)
    expires_at <= now
  end

  # When the session ends without another step: `ttl` from `from`, and
  # never past MAX_LIFE from when it opened.
  def deadline_after(from)
    [ from + ttl.seconds, (created_at || Time.current) + MAX_LIFE ].min
  end

  def step!
    now = Time.current
    update!(steps: steps + 1, last_step_at: now, expires_at: deadline_after(now))
  end

  def close!(status, reason = nil)
    update!(status: status, close_reason: reason.to_s.truncate(255).presence, closed_at: Time.current) if open?
  end

  def as_json(*)
    { "id" => id, "console" => console.name, "machine" => console.machine, "goal" => goal, "status" => status,
      "steps" => steps, "opened_by" => principal.name, "expires_at" => expires_at, "close_reason" => close_reason,
      "on_mission" => on_mission_id, "created_at" => created_at, "last_step_at" => last_step_at, "closed_at" => closed_at }
  end
end
