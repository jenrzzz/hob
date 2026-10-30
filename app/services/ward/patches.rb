module Ward
  # The "patches" check (WARD.md): what each Coolify server's own weekly
  # patch check found, as lines a run is made of, so pending security
  # updates and a needed reboot are findings like any other. A distro has
  # already matched its packages against its advisories; ward does not redo
  # that with versions it cannot compare. Fed by the inventory sync, which
  # already holds the servers: a run is posted when what Coolify says
  # changes, and at least daily so the check is not stale while it holds.
  class Patches
    SLUG = "patches".freeze
    DESCRIPTION = "Coolify's patch check per server: pending security updates, a reboot needed".freeze
    INTERVAL = 1.day
    GRACE = 1.day
    # Coolify checks weekly; older than this, it has stopped.
    CHECK_AGE = 8.days
    PACKAGES_SHOWN = 8

    def self.check
      WardCheck.find_or_create_by!(slug: SLUG) do |c|
        c.description = DESCRIPTION
        c.interval_seconds = INTERVAL.to_i
        c.grace_seconds = GRACE.to_i
      end
    end

    # -> the run posted, or nil when nothing changed and one is not due.
    def self.ingest!(servers, now: Time.current)
      lines = lines_for(servers, now: now)
      check = self.check
      last = check.last_run
      due = last.nil? || check.last_completed_at.nil? || check.last_completed_at <= now - INTERVAL + 5.minutes
      return nil unless due || last.lines != Ingest.parse(lines)

      Ingest.call(check: check, lines: lines, exit_code: 0, finished_at: now)
    end

    # One server's patch check → "LEVEL host: ..." lines.
    def self.lines_for(servers, now: Time.current)
      servers.sort_by { |s| s["name"].to_s }.flat_map do |server|
        name = server["name"].presence || server["uuid"]
        settings = server["settings"].is_a?(Hash) ? server["settings"] : {}
        result = settings["patch_check_result"]
        result = (JSON.parse(result) rescue nil) if result.is_a?(String)
        checked_at = (Time.zone.parse(settings["patch_checked_at"].to_s) rescue nil)

        if settings["patch_check_error"].present?
          next [ "ERROR #{name}: Coolify's patch check failed: #{settings['patch_check_error'].to_s.squish.truncate(200)}" ]
        end
        next [ "WARN #{name}: Coolify has no patch check for it" ] unless result.is_a?(Hash) && checked_at

        lines = []
        lines << "WARN #{name}: Coolify's patch check is more than #{CHECK_AGE.in_days.to_i} days old" if checked_at < now - CHECK_AGE
        security = Array(result["updates"]).select { |u| u.is_a?(Hash) && u["security"] == true }
        count = [ security.size, result["security_updates"].to_i ].max
        if count.positive?
          packages = security.filter_map { |u| u["package"].presence }.uniq.sort
          shown = packages.first(PACKAGES_SHOWN).join(", ")
          shown += " and #{packages.size - PACKAGES_SHOWN} more" if packages.size > PACKAGES_SHOWN
          lines << "WARN #{name}: #{count} security update#{'s' unless count == 1} pending#{": #{shown}" if shown.present?}"
        end
        lines << "WARN #{name}: reboot required; what is installed is not all running, a kernel included if one was updated" if result["reboot_required"] == true
        lines << "OK #{name}: no security updates pending (#{result['total_updates'].to_i} others)" if count.zero?
        lines
      end
    end
  end
end
