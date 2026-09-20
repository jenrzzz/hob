module Ward
  # The clock the ward keeps without a scheduler: run from every ingest, from
  # every status read, and hourly by `hob:ward:sweep` (a Coolify scheduled
  # task on the hob container). It raises a stale finding for a check that
  # has gone quiet, and reopens findings whose acknowledgement has lapsed.
  # Idempotent and cheap. When it changes something outside an ingest, it
  # writes a sweep run (no exit code, no lines) so the change is on the
  # record and gets triaged like any other.
  class Sweep
    STALE_LEVEL = "error".freeze

    def self.call(now: Time.current, into: nil, triage: true)
      new(now: now).call(into: into, triage: triage)
    end

    def initialize(now:)
      @now = now
    end

    # -> the run the changes were recorded on, or nil when nothing changed.
    def call(into: nil, triage: true)
      changes = Hash.new { |h, k| h[k] = [] }
      stale_checks = []
      WardCheck.transaction do
        WardCheck.enabled.find_each do |check|
          if check.stale?(now: @now)
            finding = check.findings.find_by(fingerprint: WardFinding::STALE_FINGERPRINT)
            if finding.nil?
              finding = check.findings.create!(
                fingerprint: WardFinding::STALE_FINGERPRINT, level: STALE_LEVEL, subject: check.slug, message: stale_message(check),
                occurrences: 1, first_seen_at: @now, last_seen_at: @now
              )
              changes["new"] << finding.id
              stale_checks << check
            elsif finding.resolved?
              finding.update!(resolved_at: nil, resolved_run_id: nil, last_seen_at: @now, occurrences: finding.occurrences + 1,
                              message: stale_message(check))
              changes["reopened"] << finding.id
              stale_checks << check
            else
              finding.update!(last_seen_at: @now, message: stale_message(check))
            end
          end
        end

        WardFinding.unresolved.where.not(acknowledged_at: nil).where(ack_until: ..@now).find_each do |finding|
          finding.update!(acknowledged_at: nil, acknowledged_by: nil, ack_until: nil)
          changes["expired_acks"] << finding.id
        end
      end
      return into if changes.empty?

      run = into || sweep_run(changes, stale_checks)
      merge!(run, changes)
      Triage.call(run) if into.nil? && triage
      run
    end

    private

    def stale_message(check)
      days = ((@now - (check.last_completed_at || check.created_at)) / 1.day).round
      "no complete #{check.slug} run for #{days} day#{'s' unless days == 1}; the scanner may have stopped"
    end

    # A run to hang sweep-only changes on: the stale check's if there is
    # exactly one, else the check of the first affected finding.
    def sweep_run(changes, stale_checks)
      check = stale_checks.first || WardFinding.find(changes.values.flatten.first).check
      WardRun.create!(check: check, exit_code: nil, complete: false, lines: [], counts: {}, created_at: @now)
    end

    def merge!(run, changes)
      diff = (run.diff || {}).dup
      changes.each { |key, ids| diff[key] = Array(diff[key]) | ids }
      run.update!(diff: diff)
    end
  end
end
