module Ward
  # A posted report becomes a run and a diff against the findings on file.
  # `lines` is what security/audit.py printed: `LEVEL message` per line and a
  # trailing `OK=.. WARN=..` tally, either as an array or one text blob. OK
  # lines are context, never findings. Exit 2 means the audit did not finish:
  # its findings are recorded, but nothing absent from it is resolved, since
  # a partial scan cannot show a port has closed.
  class Ingest
    LINE = /\A(OK|WARN|FAIL|ERROR)\s+(.*)\z/
    TALLY = /\AOK=\d+ WARN=\d+ FAIL=\d+ ERROR=\d+\z/

    def self.call(**args)
      new(**args).call
    end

    def initialize(check:, lines:, exit_code:, principal: nil, started_at: nil, finished_at: nil, mission_id: nil, triage: true)
      @check = check.is_a?(WardCheck) ? check : WardCheck.find_by(slug: check.to_s)
      raise Invalid, "no ward check named #{check.to_s.inspect}; register it with hob:ward:check" if @check.nil?

      @lines = Ingest.parse(lines)
      @exit_code = Integer(exit_code)
      @principal = principal
      @started_at = started_at
      @finished_at = finished_at
      @mission_id = mission_id
      @triage = triage
    rescue ArgumentError, TypeError
      raise Invalid, "exit_code must be an integer, got #{exit_code.inspect}"
    end

    # -> [[level, message], ...]
    def self.parse(lines)
      raw = lines.is_a?(String) ? lines.lines : Array(lines)
      raw.filter_map do |item|
        item = item.join(" ") if item.is_a?(Array)
        text = item.to_s.strip
        next if text.empty? || text.match?(TALLY)

        match = text.match(LINE)
        next if match.nil?

        [ match[1].downcase, match[2].strip ]
      end
    end

    def call
      now = Time.current
      complete = @exit_code != 2
      run = nil
      WardCheck.transaction do
        run = WardRun.create!(
          check: @check, principal: @principal, started_at: @started_at, finished_at: @finished_at || now,
          exit_code: @exit_code, complete: complete, lines: @lines, counts: counts, mission_id: @mission_id, created_at: now
        )
        diff = apply!(run, now)
        run.update!(diff: diff)
        @check.update!(last_completed_at: now, last_run_id: run.id) if complete
      end
      Sweep.call(now: now, into: run)
      Triage.call(run) if @triage && run.any_changes?
      run
    end

    private

    def counts
      tally = { "ok" => 0, "warn" => 0, "fail" => 0, "error" => 0 }
      @lines.each { |level, _| tally[level] += 1 }
      tally
    end

    # New, seen-again, reopened; then, for a complete run, everything the
    # check reported before and did not now is resolved.
    def apply!(run, now)
      diff = { "new" => [], "reopened" => [], "resolved" => [], "expired_acks" => [] }
      seen = {}
      @lines.each do |level, message|
        next if level == "ok"

        fingerprint = WardFinding.fingerprint_for(@check.slug, level, message)
        next if seen.key?(fingerprint)

        finding = @check.findings.find_by(fingerprint: fingerprint)
        if finding.nil?
          finding = @check.findings.create!(
            fingerprint: fingerprint, level: level, subject: WardFinding.subject_of(message), message: message,
            occurrences: 1, first_seen_at: now, last_seen_at: now, first_run_id: run.id, last_run_id: run.id
          )
          diff["new"] << finding.id
        elsif finding.resolved?
          finding.update!(resolved_at: nil, resolved_run_id: nil, last_seen_at: now, last_run_id: run.id,
                          occurrences: finding.occurrences + 1)
          diff["reopened"] << finding.id
        else
          finding.update!(last_seen_at: now, last_run_id: run.id, occurrences: finding.occurrences + 1)
        end
        seen[fingerprint] = finding
      end

      if run.complete?
        @check.findings.unresolved.where.not(fingerprint: seen.keys).find_each do |finding|
          finding.update!(resolved_at: now, resolved_run_id: run.id)
          diff["resolved"] << finding.id
        end
      end
      diff
    end
  end
end
