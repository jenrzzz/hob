# A feed the ward expects to hear from on a cadence (WARD.md): "exposure" is
# infra's security/audit.py, posted by the ward worker. A check that has not
# had a complete run within interval + grace is stale, and staleness is
# itself a finding: a scanner that stopped running must not look like a
# clean house.
class WardCheck < ApplicationRecord
  self.primary_key = :slug

  SLUG_FORMAT = /\A[a-z0-9]+(?:[._-][a-z0-9]+)*\z/

  has_many :runs, class_name: "WardRun", foreign_key: :check_slug, inverse_of: :check, dependent: :restrict_with_exception
  has_many :findings, class_name: "WardFinding", foreign_key: :check_slug, inverse_of: :check, dependent: :restrict_with_exception

  validates :slug, presence: true, uniqueness: true, format: { with: SLUG_FORMAT }
  validates :interval_seconds, :grace_seconds, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :enabled, -> { where(enabled: true) }

  def last_run
    last_run_id && WardRun.find_by(id: last_run_id)
  end

  def latest_run
    runs.order(created_at: :desc).first
  end

  # Stale when the last complete run (or, never having had one, the check's
  # own creation) is older than the expected cadence plus grace.
  def stale?(now: Time.current)
    return false unless enabled?

    (last_completed_at || created_at) < now - (interval_seconds + grace_seconds)
  end

  def deadline
    (last_completed_at || created_at) + (interval_seconds + grace_seconds)
  end
end
