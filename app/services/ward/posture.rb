module Ward
  # What the ward does about a threat on its own (THREATS.md, "Defense
  # posture"), tiered like the sentinel's effects:
  #
  #   Tier 0  automatic, read-only: re-scan, raise the scan cadence for the
  #           threat's duration, refresh the inventory, line the threat up
  #           against open findings
  #   Tier 1  automatic, reversible, household-visible: a task, a ping, a
  #           word to the household's agents, a staged proposal
  #   Tier 2  a person confirms, every time: ward only *proposes* these, with
  #           the exact action and its blast radius, and holds no grant to
  #           carry one out
  #
  # Every action lands in the threat's posture list and history with its
  # result; one that cannot be taken (no worker, no todo backend) is
  # recorded as skipped, never raised, so a missing piece never hides a
  # threat. Ward speaks when telling is worth it: at triage, when a fix
  # lands, when a proposal waits, at an indicator, at resolution, at a
  # reopening; never on a routine pass.
  module Posture
    TAGS = { "critical" => "rotating_light", "high" => "warning", "medium" => "shield", "low" => "shield", "none" => "white_check_mark" }.freeze
    WATCH_CRON = "0 */6 * * *"

    module_function

    def after_triage(threat)
      case threat.status
      when "exposed", "monitoring"
        rescan(threat)
        watch(threat)
        correlate(threat)
        verify_versions(threat) if threat.cve_like? && threat.affected.any? { |a| a["verdict"] == "unknown" }
        open_task(threat) unless threat.actor?
        tell(threat, "#{threat.actor? ? 'watching' : 'exposed'}: #{threat.title}", triage_body(threat))
      when "resolved"
        tell(threat, "not exposed: #{threat.title}", threat.resolution&.dig("evidence", "summary").to_s, quiet: true)
      end
    end

    # The upstream watch fired: the fix exists. A person decides the upgrade.
    def landed(threat, landed)
      propose(threat, tier: 2, action: "upgrade", title: "Upgrade to #{landed['tag']}",
                      detail: "#{threat.upstream['repository']} #{landed['tag']} is available (#{threat.upstream['source']}). " \
                              "Upgrade #{affected_names(threat)}, then ward verifies the running version.",
                      blast_radius: "#{affected_names(threat)} restart during the upgrade")
      note_task(threat, "upstream fix available: #{landed['tag']}")
    end

    # Something observed during the watch. Ward's own runs and a person's word
    # reset the window and may propose a Tier 2 block; an agent's flag resets
    # the window and is told, but never proposes one on its own say.
    def indicator(threat, body, by: nil, observed: true)
      threat.update!(expires_at: Time.current + window(threat)) if threat.actor?
      if observed
        propose(threat, tier: 2, action: "block", title: "Block or take offline what the indicator touched",
                        detail: "Indicator: #{body.to_s.truncate(300)}. Firewall the source or the port, or pause the service.",
                        blast_radius: affected_names(threat).presence || "the named surface")
      else
        tell(threat, "indicator reported: #{threat.title}", body.to_s.truncate(500))
      end
    end

    def resolved(threat)
      unwatch(threat)
      close_task(threat)
      tell(threat, "resolved: #{threat.title}", threat.resolution&.dig("criteria").to_s, quiet: true)
    end

    def reopened(threat, why)
      watch(threat)
      reopen_task(threat)
      tell(threat, "reopened: #{threat.title}", why)
    end

    def expired(threat)
      propose(threat, tier: nil, action: "resolve", title: "Resolve: the window passed quietly",
                      detail: "No indicators during the watch on #{threat.target.presence || 'the public surface'}. " \
                              "Confirm to resolve, or decline to watch another #{window(threat).inspect}.",
                      blast_radius: "none")
    end

    def review(threat)
      tell(threat, "still accepted: #{threat.title}",
           "Accepted by #{threat.accepted_by&.name || 'a person'}: #{threat.accepted_reason}. Patch it, or accept again.", quiet: true)
    end

    # A staged action, ready for a person: one per action while it waits.
    def propose(threat, tier:, action:, title:, detail:, blast_radius:)
      waiting = threat.pending_proposals.find { |p| p["action"] == action }
      return waiting if waiting

      proposal = { "id" => SecureRandom.alphanumeric(8).downcase, "tier" => tier, "action" => action, "title" => title,
                   "detail" => detail, "blast_radius" => blast_radius, "state" => "proposed", "at" => Time.current.utc.iso8601 }.compact
      threat.update!(proposals: threat.proposals + [ proposal ])
      threat.record!("proposal", body: title, data: proposal)
      tell(threat, "proposes: #{title}", "#{detail}\nBlast radius: #{blast_radius}\nConfirm: #{decide_hint(threat, proposal)}")
      proposal
    end

    # --- Tier 0 ---

    def rescan(threat)
      act(threat, 0, "rescan") do
        check = WardCheck.find_by(slug: "exposure")
        next "skipped: no exposure check registered" if check.nil?

        mission, before = Ward.queue_audit!(check, reason: "threat #{threat.id}: #{threat.title}")
        [ before ? "already queued" : "queued", mission.id ]
      end
    end

    # The exposure audit at a higher cadence while the threat is open: a
    # schedule of its own, removed when the threat resolves.
    def watch(threat)
      return if threat.schedule_id && Schedule.exists?(threat.schedule_id)

      act(threat, 0, "raise scan cadence") do
        worker = Principal.find_by(name: ENV.fetch("HOB_WARD_PRINCIPAL", "ward"), kind: "worker")
        next "skipped: no ward worker" if worker.nil? || !WardCheck.exists?(slug: "exposure")

        schedule = Schedule.find_or_initialize_by(created_by: nil, name: "ward-threat-#{threat.id.downcase}")
        schedule.update!(description: "the ward's raised exposure cadence for threat #{threat.id} (THREATS.md)",
                         cron: ENV.fetch("HOB_WARD_WATCH_CRON", WATCH_CRON), time_zone: ENV.fetch("HOB_TIME_ZONE", "Etc/UTC"),
                         assignee: worker, realm: "personal", title: "ward: run exposure (threat watch)", enabled: true,
                         payload: { "kind" => Sentinel::Native::WardAuditRun::KIND, "check" => "exposure", "threat" => threat.id })
        threat.update!(schedule_id: schedule.id)
        [ "exposure every #{schedule.cron}", schedule.id ]
      end
    end

    def unwatch(threat)
      return if threat.schedule_id.blank?

      act(threat, 0, "restore scan cadence") do
        Schedule.find_by(id: threat.schedule_id)&.destroy!
        threat.update!(schedule_id: nil)
        "removed"
      end
    end

    # A threat on a service with an open exposure finding escalates both: the
    # threat's severity rises a step, and the finding's subject gets a note
    # the exposure triage will read.
    def correlate(threat)
      names = threat.affected.filter_map { |a| a["name"] if a["asset"] }.uniq
      return if names.empty? || threat.actor?

      findings = WardFinding.open.where(subject: names).to_a
      return if findings.empty?

      act(threat, 0, "correlate findings") do
        rank = WardThreat::SEVERITIES.index(threat.assessed_severity.to_s) || 1
        threat.update!(assessed_severity: WardThreat::SEVERITIES[(rank + 1).clamp(1, 4)])
        findings.map(&:subject).uniq.each do |subject|
          WardNote.create!(subject: subject, body: "Threat #{threat.id} (#{threat.title}) affects this; it is open as #{threat.status}.")
        end
        [ "escalated with #{findings.size} open finding#{'s' unless findings.size == 1}", findings.map(&:id).join(",") ]
      end
    end

    # The first posture for an unverified match is to learn the version: a
    # fresh inventory if Coolify can say, and a standing ask for a probe.
    def verify_versions(threat)
      act(threat, 0, "get the version") do
        synced = Inventory.configured? ? (Inventory.sync! && "inventory refreshed; ") : ""
        unknown = threat.affected.select { |a| a["verdict"] == "unknown" }.map { |a| "#{a['name']} #{a['component']}" }
        "#{synced}awaiting a probe of #{unknown.join(', ')} (POST /v1/ward/observations, or hob:ward:inventory:observe)"
      rescue Ward::Error => e
        "inventory refresh failed: #{e.message}; awaiting a probe"
      end
    end

    # --- Tier 1 ---

    def open_task(threat)
      return if threat.todo_id.present?

      act(threat, 1, "open task") do
        todo = as_ward { Todos.create({ "title" => "ward: #{threat.title}".truncate(200), "notes" => task_notes(threat),
                                        "backend" => ENV["HOB_WARD_TODO_BACKEND"].presence, "list" => ENV["HOB_WARD_TODO_LIST"].presence }.compact) }
        threat.update!(todo_id: todo["id"])
        [ "opened", todo["id"] ]
      end
    end

    def note_task(threat, line)
      return if threat.todo_id.blank?

      act(threat, 1, "update task") { as_ward { Todos.update(threat.todo_id, "notes_append" => "#{Time.current.utc.to_date}: #{line}") } && "noted" }
    end

    def close_task(threat)
      return if threat.todo_id.blank?

      act(threat, 1, "close task") { as_ward { Todos.complete(threat.todo_id) } && "completed" }
    end

    def reopen_task(threat)
      return open_task(threat) if threat.todo_id.blank?

      act(threat, 1, "reopen task") { as_ward { Todos.reopen(threat.todo_id) } && "reopened" }
    end

    # The household's channel and phones, and, when HOB_WARD_TELL names them,
    # a mission for each of the household's agents (Skipsy, Marley) to pass
    # it on in chat.
    def tell(threat, headline, body, quiet: false)
      title = "ward: #{headline}".squish.truncate(120)
      act(threat, 1, "notify") do
        Notify.person(title: title, body: [ body.presence, "bin/rails \"hob:ward:threat:show[#{threat.id}]\"" ].compact.join("\n\n"),
                      tags: quiet ? "shield" : TAGS.fetch(threat.assessed_severity.to_s, "shield"))
        "sent: #{title}"
      end
      ENV["HOB_WARD_TELL"].to_s.split(",").map(&:strip).compact_blank.each do |name|
        act(threat, 1, "tell #{name}") do
          agent = Principal.find_by(name: name)
          next "skipped: #{name} is not an agent" unless agent&.agent?

          realm = Realm.rank_of(agent.max_clearance) < Realm.rank_of("personal") ? agent.max_clearance : "personal"
          mission = Mission.create!(assignee: agent, title: title, brief: body.to_s.truncate(2000).presence, realm: realm,
                                    payload: { "kind" => "ward.threat.notice", "threat" => threat.id, "status" => threat.status })
          [ "queued", mission.id ]
        end
      end
    end

    # --- shared ---

    # Run one action, record it with its result, never raise.
    def act(threat, tier, action)
      result, ref = begin
        Array(yield)
      rescue Todos::Error, Ward::Error, ActiveRecord::RecordInvalid, ArgumentError => e
        [ "skipped: #{e.message}" ]
      end
      entry = { "tier" => tier, "action" => action, "at" => Time.current.utc.iso8601, "result" => result.to_s.truncate(300), "ref" => ref }.compact
      threat.update!(posture: threat.posture + [ entry ])
      threat.record!("posture", body: "tier #{tier}: #{action} — #{entry['result']}", data: entry)
      entry
    end

    def as_ward(&block)
      Clearance.with(ENV.fetch("HOB_WARD_TODO_REALM", "personal")) { Current.set(surface: Ward::SURFACE, &block) }
    end

    def window(threat)
      threat.window
    end

    def affected_names(threat)
      threat.affected.filter_map { |a| a["name"] if a["asset"] }.uniq.join(", ")
    end

    def triage_body(threat)
      lines = [ threat.affected.any? ? threat.affected.first(8).map { |a| "- #{[ a['name'], a['component'], a['version'], a['verdict'], a['exposure'] ].compact.join(' · ')}" }.join("\n") : nil ]
      lines.unshift("Severity: #{threat.assessed_severity}#{" (#{threat.confidence})" if threat.confidence}")
      lines << "Window until #{threat.expires_at.utc.iso8601}" if threat.actor? && threat.expires_at
      lines.compact.join("\n")
    end

    def task_notes(threat)
      [ threat.title, threat.cve_ids.join(", ").presence, triage_body(threat), "ward threat #{threat.id}" ].compact.join("\n\n")
    end

    def decide_hint(threat, proposal)
      "bin/rails \"hob:ward:threat:decide[#{threat.id},#{proposal['id']},confirm]\""
    end
  end
end
