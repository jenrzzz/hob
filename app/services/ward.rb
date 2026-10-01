# The ward (WARD.md): hob's watch over the household's security posture.
# Checks post runs (Ward::Ingest), findings persist across them, the sweep
# notices what went quiet or whose acknowledgement lapsed (Ward::Sweep), and
# anything that changed is read by a model and put to a person (Ward::Triage).
module Ward
  class Error < StandardError; end
  class Invalid < Error; end

  # The surface ledger rows and conversations carry when the ward acts on
  # its own (a sweep from a rake task) rather than for a key.
  SURFACE = "ward".freeze

  module_function

  # A check's scheduled run as a hob schedule (SCHEDULES.md): the same
  # ward.audit mission `ward.audit.run` queues, for the ward worker, on a
  # cron line. Owned by hob (no creator); re-running retimes it.
  def schedule!(check, worker:, cron:, time_zone: ENV.fetch("HOB_TIME_ZONE", "Etc/UTC"))
    schedule = Schedule.find_or_initialize_by(created_by: nil, name: "ward-#{check.slug}")
    schedule.update!(
      description: "the ward's #{check.slug} check (WARD.md)", cron: cron, time_zone: time_zone,
      assignee: worker, realm: "personal", title: "ward: run #{check.slug}",
      payload: { "kind" => Sentinel::Native::WardAuditRun::KIND, "check" => check.slug }, enabled: check.enabled?
    )
    schedule
  end

  # The whole picture a person or `ward.status` wants: each check with its
  # last run and staleness, the open and acknowledged findings, the latest
  # triage. Sweeps first, so a stale check shows as one.
  def status(findings_limit: 50)
    Sweep.call
    checks = WardCheck.order(:slug).map do |check|
      last = check.latest_run
      {
        "slug" => check.slug, "description" => check.description, "enabled" => check.enabled?,
        "interval_seconds" => check.interval_seconds, "grace_seconds" => check.grace_seconds,
        "last_completed_at" => check.last_completed_at&.utc&.iso8601, "stale" => check.stale?,
        "deadline" => check.deadline.utc.iso8601,
        "last_run" => last && { "id" => last.id, "at" => last.created_at.utc.iso8601, "exit_code" => last.exit_code,
                                "complete" => last.complete?, "counts" => last.counts, "summary" => last.mechanical_summary },
        "open" => check.findings.open.count, "acknowledged" => check.findings.acknowledged.count
      }.compact
    end
    latest = WardRun.where.not(triage: nil).recent.first
    {
      "checks" => checks,
      "open" => WardFinding.open.by_severity.limit(findings_limit).map(&:as_json_for_ward),
      "acknowledged" => WardFinding.acknowledged.by_severity.limit(findings_limit).map(&:as_json_for_ward),
      "triage" => latest && { "run" => latest.id, "at" => latest.created_at.utc.iso8601 }.merge(latest.triage.slice("severity", "headline", "summary", "next_steps", "error"))
    }.compact
  end
end
