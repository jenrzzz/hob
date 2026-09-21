# A WARN/FAIL/ERROR line that persists across runs of a check (WARD.md).
# Keyed by a fingerprint of (check, level, message), so the same drift
# reported week after week is one finding with a growing occurrence count,
# not a new alarm each time. It resolves when a *complete* run no longer
# reports it, and reopens if a later run does. A person acknowledges one
# with a note and, optionally, an expiry: "known, reviewed, ask me again in
# ninety days" is the reviewed-decision line of SECURITY.md, with a clock.
class WardFinding < ApplicationRecord
  LEVELS = %w[warn fail error].freeze
  STATES = %w[open acknowledged resolved].freeze
  STALE_FINGERPRINT = "stale".freeze

  belongs_to :check, class_name: "WardCheck", foreign_key: :check_slug, inverse_of: :findings
  belongs_to :acknowledged_by, class_name: "Principal", optional: true

  validates :fingerprint, presence: true, uniqueness: { scope: :check_slug }
  validates :level, inclusion: { in: LEVELS }
  validates :subject, :message, presence: true

  before_create { self.id ||= ULID.generate }

  scope :unresolved, -> { where(resolved_at: nil) }
  scope :resolved, -> { where.not(resolved_at: nil) }
  scope :acknowledged, -> { unresolved.where.not(acknowledged_at: nil).where("ack_until IS NULL OR ack_until > ?", Time.current) }
  scope :open, -> { unresolved.where("acknowledged_at IS NULL OR (ack_until IS NOT NULL AND ack_until <= ?)", Time.current) }
  scope :by_severity, -> { order(Arel.sql("CASE level WHEN 'fail' THEN 0 WHEN 'error' THEN 1 ELSE 2 END"), last_seen_at: :desc) }

  def self.in_state(state)
    case state.to_s
    when "open" then open
    when "acknowledged" then acknowledged
    when "resolved" then resolved
    when "all", "" then all
    else raise ArgumentError, "state must be one of #{STATES.join(', ')}, or all"
    end
  end

  def self.fingerprint_for(check_slug, level, message)
    Digest::SHA256.hexdigest("#{check_slug}\n#{level}\n#{message}")[0, 32]
  end

  # "name: the rest" → "name"; otherwise the first word.
  def self.subject_of(message)
    head = message.to_s.split(": ", 2).first.to_s.strip
    head = message.to_s.split(/\s+/, 2).first.to_s if head.empty? || head.length > 120
    head.presence || "-"
  end

  def resolved?
    resolved_at.present?
  end

  def acknowledged?(now: Time.current)
    acknowledged_at.present? && (ack_until.nil? || ack_until > now)
  end

  def ack_expired?(now: Time.current)
    acknowledged_at.present? && ack_until.present? && ack_until <= now
  end

  def state
    return "resolved" if resolved?
    return "acknowledged" if acknowledged?

    "open"
  end

  def stale_marker?
    fingerprint == STALE_FINGERPRINT
  end

  def acknowledge!(by:, note: nil, until_at: nil)
    raise ArgumentError, "a resolved finding needs no acknowledgement" if resolved?
    raise ArgumentError, "until must be in the future" if until_at && until_at <= Time.current

    update!(acknowledged_at: Time.current, acknowledged_by: by, ack_note: note.presence, ack_until: until_at)
  end

  def unacknowledge!
    update!(acknowledged_at: nil, acknowledged_by: nil, ack_until: nil)
  end

  def as_json_for_ward
    {
      "id" => id, "check" => check_slug, "level" => level, "subject" => subject, "message" => message,
      "state" => state, "occurrences" => occurrences,
      "first_seen_at" => first_seen_at&.utc&.iso8601, "last_seen_at" => last_seen_at&.utc&.iso8601,
      "resolved_at" => resolved_at&.utc&.iso8601,
      "acknowledged_by" => acknowledged_by&.name, "ack_note" => ack_note, "ack_until" => ack_until&.utc&.iso8601
    }.compact
  end
end
