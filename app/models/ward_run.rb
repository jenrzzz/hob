# One report posted to the ward (WARD.md): the parsed lines of a check's
# run, the exit code, and what changed against the findings on file (`diff`;
# not `changes`, which is ActiveModel's). A run with `complete: false` (exit
# 2, or a sweep) could not prove anything is gone, so it never resolves a
# finding.
class WardRun < ApplicationRecord
  DIFF_KEYS = %w[new reopened resolved expired_acks].freeze

  belongs_to :check, class_name: "WardCheck", foreign_key: :check_slug, inverse_of: :runs
  belongs_to :principal, optional: true

  validates :check_slug, presence: true

  before_create { self.id ||= ULID.generate }

  scope :recent, -> { order(created_at: :desc) }
  scope :complete, -> { where(complete: true) }

  def sweep?
    exit_code.nil?
  end

  def any_changes?
    DIFF_KEYS.any? { |key| diff_ids(key).any? }
  end

  def diff_ids(key)
    Array((diff || {})[key.to_s])
  end

  def diff_findings(key)
    WardFinding.where(id: diff_ids(key)).by_severity
  end

  # "exposure: 2 new (1 FAIL), 1 resolved, incomplete (exit 2)"
  def mechanical_summary
    parts = []
    new_ids = diff_ids("new")
    if new_ids.any?
      fails = WardFinding.where(id: new_ids, level: "fail").count
      parts << "#{new_ids.size} new#{" (#{fails} FAIL)" if fails.positive?}"
    end
    parts << "#{diff_ids('reopened').size} reopened" if diff_ids("reopened").any?
    parts << "#{diff_ids('resolved').size} resolved" if diff_ids("resolved").any?
    parts << "#{diff_ids('expired_acks').size} acknowledgement(s) expired" if diff_ids("expired_acks").any?
    parts << "incomplete (exit #{exit_code})" if !sweep? && !complete?
    "#{check_slug}: #{parts.presence&.join(', ') || 'no change'}"
  end

  def triage_headline
    triage.is_a?(Hash) ? triage["headline"] : nil
  end

  def as_json_for_ward
    {
      "id" => id, "check" => check_slug, "posted_by" => principal&.name, "sweep" => sweep?,
      "started_at" => started_at&.utc&.iso8601, "finished_at" => finished_at&.utc&.iso8601,
      "exit_code" => exit_code, "complete" => complete?, "counts" => counts,
      "changes" => DIFF_KEYS.to_h { |key| [ key, diff_findings(key).map(&:as_json_for_ward) ] },
      "summary" => mechanical_summary, "triage" => triage, "mission" => mission_id,
      "created_at" => created_at.utc.iso8601
    }.compact
  end
end
