# A declared risk the ward was told about (THREATS.md): a CVE, an advisory,
# an actor threatening the house, or an anomaly ward noticed during a watch.
# The row is the current state; every change appends a WardThreatEvent, so
# "why is this resolved" is answered by the history, not by memory.
#
# Lifecycle (THREATS.md):
#
#   reported → triaged → exposed ──→ mitigating → monitoring → resolved
#                     ↘ not_exposed → resolved (no-match, with evidence)
#   exposed → awaiting_upstream → (fix lands) → mitigating → monitoring → resolved
#   any → accepted_risk   (a person, with a reason; re-surfaces at review cadence)
#   monitoring → expired  (an actor window passed quietly; proposes resolved)
#   resolved → monitoring (reopened: a regression)
class WardThreat < ApplicationRecord
  # A move the lifecycle does not have, or one only a person may make.
  class BadTransition < ArgumentError; end

  KINDS = %w[cve advisory actor anomaly].freeze
  SEVERITIES = %w[none low medium high critical].freeze
  CLAIMED_SEVERITIES = %w[low medium high critical].freeze
  SOURCE_TYPES = %w[person agent feed].freeze
  STATUSES = %w[reported triaged exposed not_exposed awaiting_upstream mitigating monitoring resolved accepted_risk expired].freeze
  CLOSED = %w[resolved].freeze

  TRANSITIONS = {
    "reported" => %w[triaged],
    "triaged" => %w[exposed not_exposed monitoring],
    "exposed" => %w[mitigating awaiting_upstream monitoring],
    "not_exposed" => %w[resolved exposed],
    "awaiting_upstream" => %w[mitigating exposed monitoring],
    "mitigating" => %w[monitoring exposed],
    "monitoring" => %w[resolved mitigating expired exposed],
    "expired" => %w[resolved monitoring],
    "accepted_risk" => %w[resolved exposed monitoring],
    "resolved" => %w[monitoring exposed]
  }.freeze
  # Only a person moves a threat here (THREATS.md): ward never accepts a
  # risk on the household's behalf.
  PERSON_ONLY = %w[accepted_risk].freeze

  TITLE_LIMIT = 200
  CVE_FORMAT = /\ACVE-\d{4}-\d{4,}\z/
  ACTOR_WINDOW = 7.days
  REVIEW_EVERY = 30.days
  SUSTAIN = 1.hour     # two passing checks at least this far apart resolve a CVE
  PASSES = 2

  belongs_to :reported_by, class_name: "Principal", optional: true
  belongs_to :accepted_by, class_name: "Principal", optional: true
  has_many :events, -> { order(:created_at, :id) }, class_name: "WardThreatEvent", foreign_key: :threat_id,
                                                     inverse_of: :threat, dependent: :restrict_with_exception

  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :title, presence: true, length: { maximum: TITLE_LIMIT }
  validates :claimed_severity, inclusion: { in: CLAIMED_SEVERITIES }, allow_nil: true
  validates :assessed_severity, inclusion: { in: SEVERITIES }, allow_nil: true
  validate :cve_ids_shape

  normalizes :cve_ids, with: ->(ids) { Array(ids).map { |id| id.to_s.strip.upcase }.compact_blank.uniq }

  before_create { self.id ||= ULID.generate }

  scope :open, -> { where.not(status: CLOSED) }
  scope :closed, -> { where(status: CLOSED) }
  scope :recent, -> { order(updated_at: :desc) }
  scope :mentioning, ->(cve_ids) { where("cve_ids && ARRAY[?]::varchar[]", Array(cve_ids)) }
  scope :by_severity, -> { order(Arel.sql("CASE assessed_severity WHEN 'critical' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END"), updated_at: :desc) }

  def self.in_state(state)
    case state.to_s
    when "open", "" then open
    when "closed" then closed
    when "all" then all
    when *STATUSES then where(status: state.to_s)
    else raise ArgumentError, "state must be open, closed, all, or one of #{STATUSES.join(', ')}"
    end
  end

  def open?
    !CLOSED.include?(status)
  end

  def cve_like?
    %w[cve advisory].include?(kind)
  end

  def actor?
    kind == "actor"
  end

  def can_move_to?(to)
    PERSON_ONLY.include?(to) ? status != to : Array(TRANSITIONS[status]).include?(to)
  end

  # Append to the history. Who did it is a principal or nil (ward itself).
  def record!(kind, body: nil, by: nil, data: {}, from: nil, to: nil)
    events.create!(kind: kind, body: body.presence, principal: by, data: data.compact, from_status: from, to_status: to)
  end

  # Move along the lifecycle, or raise: a transition the lifecycle does not
  # have is a bug in whoever asked, not something to paper over.
  def move!(to, by: nil, body: nil, data: {}, person: false)
    to = to.to_s
    raise BadTransition, "#{to} is not a threat status" unless STATUSES.include?(to)
    raise BadTransition, "only a person moves a threat to #{to}" if PERSON_ONLY.include?(to) && !person
    raise BadTransition, "a #{status} threat cannot become #{to}" unless can_move_to?(to)

    from = status
    transaction do
      update!(status: to, resolved_at: to == "resolved" ? Time.current : (from == "resolved" ? nil : resolved_at))
      record!("transition", body: body, by: by, data: data, from: from, to: to)
    end
    self
  end

  # How long an actor window runs: the reporter's, else HOB_WARD_ACTOR_WINDOW_DAYS, else a week.
  def window
    (window_days.presence || ENV["HOB_WARD_ACTOR_WINDOW_DAYS"].presence&.to_i || ACTOR_WINDOW.in_days.to_i).days
  end

  def proposal(id)
    proposals.find { |p| p["id"] == id.to_s }
  end

  def pending_proposals
    proposals.select { |p| p["state"] == "proposed" }
  end

  def unsatisfied_gotchas
    gotchas.each_with_index.reject { |g, _| g["satisfied_at"] }.map { |g, i| g.merge("index" => i) }
  end

  # An actor window passes quietly when it simply runs out: every indicator
  # pushes expires_at a whole window forward, so reaching it means none came.
  def window_passed?(now: Time.current)
    actor? && status == "monitoring" && expires_at.present? && expires_at <= now
  end

  def as_json_for_ward(history: false)
    json = {
      "id" => id, "kind" => kind, "title" => title, "status" => status, "cve_ids" => cve_ids.presence,
      "component" => component, "fixed_versions" => fixed_versions.presence,
      "claimed_severity" => claimed_severity, "assessed_severity" => assessed_severity, "confidence" => confidence,
      "exploited" => exploited? || nil, "actor" => actor, "target" => target,
      "sources" => sources, "reported_by" => reported_by&.name, "affected" => affected,
      "posture" => posture.presence, "proposals" => proposals.presence, "gotchas" => gotchas.presence,
      "upstream" => upstream, "resolution" => resolution, "expires_at" => expires_at&.utc&.iso8601,
      "window_days" => window_days, "accepted_reason" => accepted_reason, "accepted_by" => accepted_by&.name, "review_at" => review_at&.utc&.iso8601,
      "todo" => todo_id, "created_at" => created_at.utc.iso8601, "updated_at" => updated_at.utc.iso8601,
      "resolved_at" => resolved_at&.utc&.iso8601
    }.compact
    json["history"] = events.includes(:principal).map(&:as_json_for_ward) if history
    json
  end

  # One line, for listings and notifications.
  def line
    bits = [ status.tr("_", " "), assessed_severity, cve_ids.join(", ").presence ].compact_blank
    "#{title} (#{bits.join('; ')})"
  end

  private

  def cve_ids_shape
    bad = cve_ids.reject { |id| id.match?(CVE_FORMAT) }
    errors.add(:cve_ids, "must look like CVE-2026-12345: #{bad.join(', ')}") if bad.any?
  end
end
