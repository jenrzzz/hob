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
  # The worker's mission kind for reading versions (infra security/ward.py, probes.yaml).
  PROBE_KIND = "ward.probe".freeze

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

  # A ward.audit mission for the worker to run `check` now (ward.audit.run,
  # and Tier 0 posture for a threat). One at a time per check: a run already
  # queued or leased is the answer. -> [mission, queued_before]
  def queue_audit!(check, by: nil, reason: nil, request: nil)
    raise Invalid, "#{check.slug} is disabled" unless check.enabled?

    worker = Principal.find_by(name: ENV.fetch("HOB_WARD_PRINCIPAL", "ward"), kind: "worker")
    raise Invalid, "no ward worker is set up (bin/rails \"hob:ward:setup[ward]\")" if worker.nil?

    if (open = Mission.open.for(worker).where("payload->>'kind' = ? AND payload->>'check' = ?", Sentinel::Native::WardAuditRun::KIND, check.slug).first)
      return [ open, true ]
    end

    mission = Mission.create!(
      assignee: worker, created_by: by, title: "ward: run #{check.slug}", brief: reason.to_s.strip.truncate(200).presence,
      payload: { "kind" => Sentinel::Native::WardAuditRun::KIND, "check" => check.slug, "request" => request }.compact, realm: "personal"
    )
    [ mission, false ]
  end

  # A ward.probe mission: the worker reads the versions its probes.yaml
  # names now and posts them as observations (THREATS.md). One at a time;
  # an open one is the answer. -> [mission, queued_before]
  def queue_probe!(reason: nil)
    worker = Principal.find_by(name: ENV.fetch("HOB_WARD_PRINCIPAL", "ward"), kind: "worker")
    raise Invalid, "no ward worker is set up (bin/rails \"hob:ward:setup[ward]\")" if worker.nil?

    if (open = Mission.open.for(worker).where("payload->>'kind' = ?", PROBE_KIND).first)
      return [ open, true ]
    end

    mission = Mission.create!(assignee: worker, title: "ward: probe versions", brief: reason.to_s.strip.truncate(200).presence,
                              payload: { "kind" => PROBE_KIND }, realm: "personal")
    [ mission, false ]
  end

  # The threats' clock (THREATS.md): refresh the inventory when it is due
  # (or just the scan targets, without a Coolify token), then let the
  # resolver move threats along. A Coolify that cannot be reached is logged
  # and the resolver runs on what is known.
  def threat_upkeep!(now: Time.current)
    inventory = begin
      if Inventory.due?(now: now) then Inventory.sync!(now: now)
      elsif !Inventory.configured? then { "assets" => Inventory.new(client: nil, now: now).sync_scan_targets.size }
      end
    rescue Ward::Error => e
      Rails.logger.warn("ward inventory sync: #{e.message}")
      { "error" => e.message }
    end
    { "inventory" => inventory, "threats" => Resolver.call(now: now) }.compact
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
    threats = WardThreat.open.by_severity.limit(findings_limit)
    {
      "checks" => checks,
      "open" => WardFinding.open.by_severity.limit(findings_limit).map(&:as_json_for_ward),
      "acknowledged" => WardFinding.acknowledged.by_severity.limit(findings_limit).map(&:as_json_for_ward),
      "threats" => Threats.as_list(threats).presence,
      "triage" => latest && { "run" => latest.id, "at" => latest.created_at.utc.iso8601 }.merge(latest.triage.slice("severity", "headline", "summary", "next_steps", "error"))
    }.compact
  end
end
