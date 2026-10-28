namespace :hob do
  desc "Onboard a surface: mint its hob key and set HOB_URL/HOB_ADDR/HOB_KEY on its Coolify app. " \
       "bin/rails \"hob:provision[surface,coolify_app_uuid,clearance=personal,principal=jenner]\" (RESTART=0 to skip the restart)"
  task :provision, [ :surface, :app, :clearance, :principal ] => :environment do |_task, args|
    if args[:surface].blank? || args[:app].blank?
      abort "usage: bin/rails \"hob:provision[surface,coolify_app_uuid,clearance=personal,principal=jenner]\""
    end

    result = Provision.new.call(surface: args[:surface], app: args[:app],
                                clearance: args[:clearance].presence || "personal",
                                principal: args[:principal].presence || "jenner",
                                restart: ENV["RESTART"] != "0")
    puts "#{result.surface}: set #{result.env.join(', ')} on #{result.app}; " \
         "rotated #{result.rotated} old key(s); #{result.restarted ? 'restart queued' : 'not restarted'}"
  end
end

namespace :hob do
  desc "Onboard an external agent (SENTINEL.md): create its principal and mint a key, shown once. " \
       "bin/rails \"hob:agent[muse,clearance=household,surface=muse]\" CHANNEL=https://ntfy.sh/<topic> " \
       "(re-running rotates the key; with a clearance, it also moves the agent's own grant to it)"
  task :agent, [ :name, :clearance, :surface ] => :environment do |_task, args|
    abort "usage: bin/rails \"hob:agent[name,clearance=household,surface=name]\" CHANNEL=" if args[:name].blank?

    requested = args[:clearance].presence
    Realm.rank_of(requested || "household")
    agent = Principal.find_or_create_by!(name: args[:name]) { |p| p.kind = "agent"; p.max_clearance = requested || "household" }
    abort "#{agent.name} is a #{agent.kind}, not an agent" unless agent.agent?
    # A key's clearance is min(key default, principal grant), so a key minted
    # above the grant would be a household key with a personal label. A named
    # clearance moves the grant, up or down; none keeps the agent's own.
    if requested && agent.max_clearance != requested
      puts "#{agent.name}: clearance #{agent.max_clearance} → #{requested}"
      agent.update!(max_clearance: requested)
    end
    clearance = agent.max_clearance
    agent.update!(channel: ENV["CHANNEL"]) if ENV.key?("CHANNEL")

    surface = args[:surface].presence || agent.name
    token = ApiKey.issue!(principal: agent, surface: surface, default_clearance: clearance)
    rotated = agent.api_keys.where(surface: surface).where.not(token_digest: ApiKey.digest(token)).destroy_all.size
    rules = agent.sentinel_policies.count + SentinelPolicy.where(principal_id: nil).count
    puts "#{agent.name}: agent key (shown once): #{token}"
    puts "clearance #{clearance}, surface #{surface}, rotated #{rotated} old key(s); " \
         "#{rules.zero? ? 'no policies yet — every request will be denied until you add some' : "#{rules} policy rule(s) apply"}"
    puts agent.channel.present? ? "missions announced on #{agent.channel}" : "no channel: #{agent.name} finds missions by polling only (hob:channel to set one)"
  end

  desc "Set a principal's channel: the ntfy topic that hears about its missions (queued for an agent; settled for whoever " \
       "queued them). bin/rails \"hob:channel[skipsy,https://ntfy.sh/hob-skipsy]\"; an empty URL clears it; no arguments lists them"
  task :channel, [ :principal, :url ] => :environment do |_task, args|
    if args[:principal].blank?
      Principal.order(:kind, :name).each { |p| puts "#{p.name.ljust(16)} #{p.kind.ljust(8)} #{p.channel || '-'}" }
      next
    end

    principal = Principal.find_by!(name: args[:principal])
    principal.update!(channel: args[:url])
    puts principal.channel.present? ? "#{principal.name}: missions announced on #{principal.channel}" : "#{principal.name}: no channel"
  end

  desc "Open or close an agent's inbox to hob.agent.message from its tier when the agent is cleared higher: " \
       "bin/rails \"hob:inbox[skipsy,open]\"; open|closed; no state shows it; no arguments lists the open ones"
  task :inbox, [ :agent, :state ] => :environment do |_task, args|
    if args[:agent].blank?
      open = Principal.agents.where(accepts_lower_messages: true).order(:name).pluck(:name)
      puts open.any? ? open.join("\n") : "no agent accepts messages from below its clearance"
      next
    end

    agent = Principal.agents.find_by!(name: args[:agent])
    case args[:state]
    when "open" then agent.update!(accepts_lower_messages: true)
    when "closed" then agent.update!(accepts_lower_messages: false)
    when nil, "" then nil
    else abort "state must be open or closed, got #{args[:state].inspect}"
    end
    puts "#{agent.name} (#{agent.max_clearance}): " \
         "#{agent.accepts_lower_messages? ? 'accepts' : 'refuses'} messages from agents below its clearance"
  end

  desc "List agent-to-agent messages (hob.agent.message), newest first, for a person to audit: bin/rails \"hob:messages[50]\""
  task :messages, [ :limit ] => :environment do |_task, args|
    rows = AgentMessage.newest_first.limit((args[:limit].presence || 50).to_i).includes(:sender, :recipient)
    puts "no agent messages" if rows.empty?
    rows.each do |m|
      puts "#{m.id}  #{m.created_at.utc.iso8601}  #{m.sender.name} → #{m.recipient.name}  " \
           "#{m.read? ? "read #{m.read_at.utc.iso8601}" : 'unread'}  sentinel/#{m.sentinel_request_id}"
      puts "  #{m.body}"
    end
  end

  namespace :calendar do
    desc "Let an agent push calendar events for a person (hob.calendar.push): bin/rails \"hob:calendar:contributor[jenner,skipsy]\"; " \
         "REMOVE=1 takes it away again (what the agent already pushed stays until PURGE=1 goes with it)"
    task :contributor, [ :owner, :agent ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:calendar:contributor[owner,agent]\" REMOVE=1 PURGE=1" if args[:owner].blank? || args[:agent].blank?

      owner = Principal.find_by!(name: args[:owner])
      agent = Principal.find_by!(name: args[:agent])
      if ENV["REMOVE"] == "1"
        removed = CalendarContributor.where(owner: owner, agent: agent).delete_all
        purged = ENV["PURGE"] == "1" ? CalendarEvent.where(owner: owner, source_agent: agent).delete_all : 0
        puts "#{agent.name} #{removed.zero? ? 'was not pushing' : 'no longer pushes'} for #{owner.name}; #{purged} event(s) purged, " \
             "#{CalendarEvent.where(owner: owner, source_agent: agent).count} still in the mirror"
      else
        CalendarContributor.find_or_create_by!(owner: owner, agent: agent)
        puts "#{agent.name} may push calendar events for #{owner.name}"
      end
    end

    desc "List who may push calendar events for whom, and how much of the mirror each has filled"
    task contributors: :environment do
      rows = CalendarContributor.includes(:owner, :agent).order(:owner_id, :agent_id)
      puts "no calendar contributors; bin/rails \"hob:calendar:contributor[owner,agent]\"" if rows.empty?
      rows.each do |row|
        events = CalendarEvent.where(owner: row.owner, source_agent: row.agent)
        puts "#{row.agent.name} → #{row.owner.name}: #{events.count} event(s), #{events.where(visibility: 'details').count} with details, " \
             "last push #{events.maximum(:updated_at)&.utc&.iso8601 || 'never'}"
      end
    end

    # Calendar backends (CALENDARS.md): where the household's calendars are read from.
    desc "Register (or update) a calendar backend (CALENDARS.md). A feed: bin/rails \"hob:calendar:backend[kids-ics,ics,household]\" " \
         "URL_ENV=KIDS_ICS_URL (or URL=<the feed>) LABEL=Kids. Fastmail: bin/rails \"hob:calendar:backend[jenner-fastmail,fastmail,personal]\" " \
         "USERNAME=you@fastmail.com KEY_ENV=FASTMAIL_APP_PASSWORD (or KEY=). Any kind: OWNER=jenner CALENDARS=Family,Kids " \
         "VISIBILITY=free_busy TIME_ZONE=America/Los_Angeles ENABLED=0"
    task :backend, [ :name, :kind, :realm ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:calendar:backend[name,kind=ics|fastmail|caldav,realm=personal]\" URL= | URL_ENV= | USERNAME= KEY_ENV=" if args[:name].blank?

      Clearance.with("intimate") do
        row = CalendarBackend.find_or_initialize_by(name: args[:name])
        row.kind = args[:kind].presence || row.kind || "ics"
        row.realm = args[:realm].presence || row.realm || "personal"
        row.principal = Principal.find_by!(name: ENV["OWNER"]) if ENV["OWNER"].present?
        row.principal ||= Principal.find_by!(name: "jenner")
        config = row.config.dup
        # URL is a feed's address (a secret) or a CalDAV calendar home; KEY a password. Either can come from an env var instead.
        { "URL" => "url", "KEY" => "key" }.each do |env, key|
          config = config.except(key, "#{key}_env").merge(key => ENV[env]) if ENV[env].present?
          config = config.except(key, "#{key}_env").merge("#{key}_env" => ENV["#{env}_ENV"]) if ENV["#{env}_ENV"].present?
        end
        config["username"] = ENV["USERNAME"] if ENV["USERNAME"].present?
        config["name"] = ENV["LABEL"].presence if ENV.key?("LABEL")
        config["calendars"] = ENV["CALENDARS"].split(",").map(&:strip).compact_blank.presence if ENV.key?("CALENDARS")
        config["visibility"] = ENV["VISIBILITY"].presence if ENV.key?("VISIBILITY")
        config["time_zone"] = ENV["TIME_ZONE"].presence if ENV.key?("TIME_ZONE")
        row.config = config.compact
        row.enabled = ENV["ENABLED"] != "0" if ENV.key?("ENABLED")
        created = row.new_record?
        row.save!
        puts "#{row.name}: #{created ? 'registered' : 'updated'}; #{row.kind}, realm #{row.realm}, owner #{row.principal.name}, " \
             "#{row.free_busy? ? 'free/busy only' : 'with details'}, floating times in #{row.time_zone.tzinfo.name}" \
             "#{row.config['calendars'] ? ", only #{row.config['calendars'].join(', ')}" : ''}#{row.enabled? ? '' : ', disabled'}"
        row.config.slice("url_env", "key_env").each_value { |env| puts "  #{env} is not set in this environment" if ENV[env].blank? }
        puts "check it: bin/rails \"hob:calendar:check[#{row.name}]\""
      end
    end

    desc "List calendar backends and whether each answers"
    task backends: :environment do
      Clearance.with("intimate") do
        rows = CalendarBackend.includes(:principal).order(:name)
        puts "no calendar backends; bin/rails \"hob:calendar:backend[name,ics,realm]\" URL_ENV=" if rows.empty?
        rows.each do |row|
          state = "disabled" unless row.enabled?
          state ||= begin
            row.adapter.check && "reachable"
          rescue Calendars::Error => e
            "unreachable: #{e.message}"
          end
          puts "#{row.name.ljust(24)} #{row.kind.ljust(9)} #{row.realm.ljust(10)} #{row.principal.name.ljust(10)} " \
               "#{(row.free_busy? ? 'free_busy' : 'details').ljust(9)} #{state}"
        end
      end
    end

    desc "Ask one calendar backend how it is, and which calendars it reaches: bin/rails \"hob:calendar:check[jenner-fastmail]\""
    task :check, [ :name ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:calendar:check[name]\"" if args[:name].blank?

      Clearance.with("intimate") do
        row = CalendarBackend.find_by!(name: args[:name])
        begin
          status = row.adapter.check
          puts "#{row.name}: reachable"
          status.except("reachable").each { |name, value| puts "  #{name}: #{value.is_a?(String) ? value : value.to_json}" }
        rescue Calendars::Error => e
          abort "#{row.name}: #{e.class.name.demodulize.downcase}: #{e.message}"
        end
      end
    end
  end

  # Mail backends (MAIL.md): the household's mail accounts.
  namespace :mail do
    desc "Register (or update) a mail backend (MAIL.md): bin/rails \"hob:mail:backend[jenner-fastmail,fastmail,personal]\" " \
         "KEY_ENV=FASTMAIL_API_TOKEN (or KEY=<the token>). Any kind: OWNER=jenner MAILBOXES=Household,Receipts READ_ONLY=1 " \
         "URL=<a JMAP session URL; jmap only> ENABLED=0"
    task :backend, [ :name, :kind, :realm ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:mail:backend[name,kind=fastmail|jmap,realm=personal]\" KEY_ENV= | KEY=" if args[:name].blank?

      Clearance.with("intimate") do
        row = MailBackend.find_or_initialize_by(name: args[:name])
        row.kind = args[:kind].presence || row.kind || "fastmail"
        row.realm = args[:realm].presence || row.realm || "personal"
        row.principal = Principal.find_by!(name: ENV["OWNER"]) if ENV["OWNER"].present?
        row.principal ||= Principal.find_by!(name: "jenner")
        config = row.config.dup
        config = config.except("key", "key_env").merge("key" => ENV["KEY"]) if ENV["KEY"].present?
        config = config.except("key", "key_env").merge("key_env" => ENV["KEY_ENV"]) if ENV["KEY_ENV"].present?
        config["url"] = ENV["URL"].presence if ENV.key?("URL")
        config["mailboxes"] = ENV["MAILBOXES"].split(",").map(&:strip).compact_blank.presence if ENV.key?("MAILBOXES")
        config["read_only"] = (ENV["READ_ONLY"] == "1" || nil) if ENV.key?("READ_ONLY")
        row.config = config.compact
        row.enabled = ENV["ENABLED"] != "0" if ENV.key?("ENABLED")
        created = row.new_record?
        row.save!
        puts "#{row.name}: #{created ? 'registered' : 'updated'}; #{row.kind}, realm #{row.realm}, owner #{row.principal.name}" \
             "#{row.confined? ? ", only #{row.config['mailboxes'].join(', ')}" : ''}#{row.read_only? ? ', read-only' : ''}" \
             "#{row.enabled? ? '' : ', disabled'}"
        puts "  #{row.config['key_env']} is not set in this environment" if row.config["key_env"].present? && ENV[row.config["key_env"]].blank?
        puts "check it: bin/rails \"hob:mail:check[#{row.name}]\""
      end
    end

    desc "List mail backends and whether each answers"
    task backends: :environment do
      Clearance.with("intimate") do
        rows = MailBackend.includes(:principal).order(:name)
        puts "no mail backends; bin/rails \"hob:mail:backend[name,fastmail,realm]\" KEY_ENV=" if rows.empty?
        rows.each do |row|
          state = "disabled" unless row.enabled?
          state ||= begin
            row.adapter.check && "reachable"
          rescue Email::Error => e
            "unreachable: #{e.message}"
          end
          puts "#{row.name.ljust(24)} #{row.kind.ljust(9)} #{row.realm.ljust(10)} #{row.principal.name.ljust(10)} " \
               "#{(row.read_only? ? 'read-only' : 'read-write').ljust(10)} #{state}"
        end
      end
    end

    desc "Ask one mail backend how it is: the account, its mailboxes, and whether it can send: bin/rails \"hob:mail:check[jenner-fastmail]\""
    task :check, [ :name ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:mail:check[name]\"" if args[:name].blank?

      Clearance.with("intimate") do
        row = MailBackend.find_by!(name: args[:name])
        begin
          status = row.adapter.check
          puts "#{row.name}: reachable"
          status.except("reachable").each { |name, value| puts "  #{name}: #{value.is_a?(String) ? value : value.to_json}" }
          row.adapter.mailboxes.each { |mailbox| puts "    #{mailbox['path']}#{mailbox['role'] ? " (#{mailbox['role']})" : ''}" }
        rescue Email::Error => e
          abort "#{row.name}: #{e.class.name.demodulize.downcase}: #{e.message}"
        end
      end
    end
  end

  namespace :texts do
    desc "Register (or update) a text backend (TEXTS.md): bin/rails \"hob:texts:backend[jenner-messages,herald,http://mini.tailnet.ts.net:8379,personal]\" " \
         "KEY_ENV=HERALD_KEY (or KEY=<the key>). OWNER=jenner ADDR=<tailnet IP> READ_ONLY=1 ENABLED=0"
    task :backend, [ :name, :kind, :url, :realm ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:texts:backend[name,kind=herald,url,realm=personal]\" KEY_ENV= | KEY=" if args[:name].blank?

      Clearance.with("intimate") do
        row = TextBackend.find_or_initialize_by(name: args[:name])
        row.kind = args[:kind].presence || row.kind || "herald"
        row.realm = args[:realm].presence || row.realm || "personal"
        row.principal = Principal.find_by!(name: ENV["OWNER"]) if ENV["OWNER"].present?
        row.principal ||= Principal.find_by!(name: "jenner")
        config = row.config.dup
        config["url"] = args[:url] if args[:url].present?
        config = config.except("key", "key_env").merge("key" => ENV["KEY"]) if ENV["KEY"].present?
        config = config.except("key", "key_env").merge("key_env" => ENV["KEY_ENV"]) if ENV["KEY_ENV"].present?
        config["addr"] = ENV["ADDR"].presence if ENV.key?("ADDR")
        config["read_only"] = (ENV["READ_ONLY"] == "1" || nil) if ENV.key?("READ_ONLY")
        row.config = config.compact
        row.enabled = ENV["ENABLED"] != "0" if ENV.key?("ENABLED")
        created = row.new_record?
        row.save!
        puts "#{row.name}: #{created ? 'registered' : 'updated'}; #{row.kind} at #{row.url}, realm #{row.realm}, owner #{row.principal.name}" \
             "#{row.read_only? ? ', read-only' : ''}#{row.enabled? ? '' : ', disabled'}"
        puts "  #{row.config['key_env']} is not set in this environment" if row.config["key_env"].present? && ENV[row.config["key_env"]].blank?
        puts "check it: bin/rails \"hob:texts:check[#{row.name}]\""
      end
    end

    desc "List text backends and whether each answers"
    task backends: :environment do
      Clearance.with("intimate") do
        rows = TextBackend.includes(:principal).order(:name)
        puts "no text backends; bin/rails \"hob:texts:backend[name,herald,url,realm]\" KEY_ENV=" if rows.empty?
        rows.each do |row|
          state = "disabled" unless row.enabled?
          state ||= begin
            row.adapter.check && "reachable"
          rescue Texts::Error => e
            "unreachable: #{e.message}"
          end
          puts "#{row.name.ljust(24)} #{row.kind.ljust(8)} #{row.realm.ljust(10)} #{row.principal.name.ljust(10)} " \
               "#{(row.read_only? ? 'read-only' : 'read-send').ljust(10)} #{state}"
        end
      end
    end

    desc "Ask one text backend how it is: herald, the Messages database, Contacts, and the key: bin/rails \"hob:texts:check[jenner-messages]\""
    task :check, [ :name ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:texts:check[name]\"" if args[:name].blank?

      Clearance.with("intimate") do
        row = TextBackend.find_by!(name: args[:name])
        begin
          status = row.adapter.check
          puts "#{row.name}: reachable"
          status.except("reachable").each { |name, value| puts "  #{name}: #{value.is_a?(String) ? value : value.to_json}" }
        rescue Texts::Error => e
          abort "#{row.name}: #{e.class.name.demodulize.downcase}: #{e.message}"
        end
      end
    end
  end

  desc "Mint a key for an existing principal, shown once: bin/rails \"hob:key[jenner,phone]\" for the companion app " \
       "(clients/ios); the clearance defaults to the principal's own"
  task :key, [ :principal, :surface, :clearance ] => :environment do |_task, args|
    abort "usage: bin/rails \"hob:key[principal,surface,clearance=principal's]\"" if args[:principal].blank? || args[:surface].blank?

    principal = Principal.find_by!(name: args[:principal])
    clearance = args[:clearance].presence || principal.max_clearance
    Realm.rank_of(clearance)
    token = ApiKey.issue!(principal: principal, surface: args[:surface], default_clearance: clearance)
    puts "#{principal.name}: key for #{args[:surface]} (shown once): #{token}"
    puts "clearance #{clearance}; #{principal.trusted? ? 'a person: may decide petitions and register a phone' : "a #{principal.kind}: cannot decide or register a phone"}"
  end

  desc "Link a person to their identity at the household's OIDC provider so they can sign in to /admin: " \
       "bin/rails \"hob:link[jenner,<sub>]\" (the sign-in page shows the sub); an empty sub unlinks and ends their sessions"
  task :link, [ :principal, :subject ] => :environment do |_task, args|
    abort "usage: bin/rails \"hob:link[principal,subject]\"" if args[:principal].blank?

    principal = Principal.find_by!(name: args[:principal])
    abort "#{principal.name} is a #{principal.kind}; only people sign in" unless principal.trusted?
    principal.update!(oidc_subject: args[:subject])
    puts principal.oidc_subject ? "#{principal.name} signs in as #{principal.oidc_subject}" : "#{principal.name}: unlinked"
  end

  namespace :sentinel do
    desc "Set a policy rule. bin/rails \"hob:sentinel:policy[muse,hob.complete,review]\"; agent '*' = every agent; " \
         "GUIDANCE='...' CONSTRAINTS='{\"role\":[\"cheap-classifier\"]}' LIMITS='{\"per_day\":50}'"
    task :policy, [ :agent, :capability, :effect ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:sentinel:policy[agent|*,capability|*,allow|deny|review|confirm]\"" if args[:effect].blank?

      principal = args[:agent] == "*" ? nil : Principal.find_by!(name: args[:agent])
      rule = SentinelPolicy.find_or_initialize_by(principal: principal, capability: args[:capability].presence || "*")
      rule.effect = args[:effect]
      rule.guidance = ENV["GUIDANCE"] if ENV.key?("GUIDANCE")
      rule.constraints = JSON.parse(ENV["CONSTRAINTS"]) if ENV["CONSTRAINTS"].present?
      rule.limits = JSON.parse(ENV["LIMITS"]) if ENV["LIMITS"].present?
      rule.save!
      puts "#{principal&.name || 'every agent'} × #{rule.capability}: #{rule.effect}" \
           "#{rule.constraints.presence && " constraints #{rule.constraints.to_json}"}" \
           "#{rule.limits.presence && " limits #{rule.limits.to_json}"}"
    end

    desc "Set the charter: how far the steward may go with an agent's capability requests. " \
         "bin/rails \"hob:sentinel:charter[muse,allow|review|confirm|deny]\" GUIDANCE='...' LIMITS='{\"per_day\":10,\"builds_per_day\":3}'"
    task :charter, [ :agent, :effect ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:sentinel:charter[agent|*,allow|review|confirm|deny]\"" if args[:effect].blank?

      Rake::Task["hob:sentinel:policy"].invoke(args[:agent].presence || "*", Sentinel::Steward::CHARTER, args[:effect])
    end

    desc "List requests and petitions waiting for a person"
    task pending: :environment do
      Clearance.with("intimate") do
        rows = SentinelRequest.pending.recent.includes(:capability, :principal)
        puts "no requests pending" if rows.empty?
        rows.each do |r|
          puts "#{r.id}  #{r.created_at.utc.iso8601}  #{r.principal.name} → #{r.capability.name}  (#{r.rationale})"
          puts "  arguments: #{r.arguments.to_json}"
          puts "  reason: #{r.reason}" if r.reason.present?
        end
        petitions = Petition.where(status: %w[pending failed]).recent.includes(:principal)
        puts "no petitions pending" if petitions.empty?
        petitions.each do |p|
          puts "#{p.id}  #{p.created_at.utc.iso8601}  #{p.principal.name} petitions [#{p.status}]: #{p.want}"
          puts "  steward: #{p.action} — #{p.rationale}" if p.action
          puts "  recommends: #{p.capability_name} at #{p.effect}" if p.capability_name
          puts "  spec: #{p.spec['description']}" if p.spec["description"].present?
          puts "  error: #{p.error}" if p.error.present?
          puts "  decide: bin/rails \"hob:sentinel:petition[#{p.id},grant|build|deny]\""
        end
      end
    end

    desc "List open petitions (pending, building, proposed, failed)"
    task petitions: :environment do
      Clearance.with("intimate") do
        rows = Petition.where(status: %w[pending building proposed failed]).recent.includes(:principal)
        puts "no open petitions" if rows.empty?
        rows.each do |p|
          puts "#{p.id}  #{p.status.ljust(9)}  #{p.principal.name}  #{p.capability_name || '-'}  #{p.want.truncate(70)}"
          puts "  #{p.pull_request}" if p.pull_request.present?
          puts "  mission #{p.mission_id}" if p.mission_id.present? && p.status == "building"
        end
      end
    end

    desc "Decide a petition as a person. bin/rails \"hob:sentinel:petition[<id>,grant|build|deny,jenner]\" " \
         "CAPABILITY= EFFECT=allow|review|confirm RATIONALE= GUIDANCE= CONSTRAINTS='{}' LIMITS='{}'"
    task :petition, [ :id, :decision, :principal ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:sentinel:petition[id,grant|build|deny,principal=jenner]\"" if args[:id].blank? || args[:decision].blank?

      Clearance.with("intimate") do
        decider = Principal.find_by!(name: args[:principal].presence || "jenner")
        row = Sentinel.decide_petition!(
          Petition.find(args[:id]), decision: args[:decision], decider: decider,
          capability: ENV["CAPABILITY"].presence, effect: ENV["EFFECT"].presence, rationale: ENV["RATIONALE"].presence,
          guidance: ENV["GUIDANCE"].presence,
          constraints: ENV["CONSTRAINTS"].present? ? JSON.parse(ENV["CONSTRAINTS"]) : nil,
          limits: ENV["LIMITS"].present? ? JSON.parse(ENV["LIMITS"]) : nil
        )
        puts "#{row.id}: #{row.status}#{row.capability_name && " #{row.capability_name}"}#{row.effect && " at #{row.effect}"}" \
             "#{row.mission_id && row.status == 'building' ? " (mission #{row.mission_id})" : ''}#{row.error && " (#{row.error})"}"
      end
    end

    desc "Decide a pending request as a person. bin/rails \"hob:sentinel:decide[<id>,allow|deny,jenner]\" RATIONALE='...' " \
         "FABRICATED=1 (with deny: a spot-checked claim's quote was never said; the agent freezes)"
    task :decide, [ :id, :decision, :principal ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:sentinel:decide[id,allow|deny,principal=jenner]\"" if args[:id].blank? || args[:decision].blank?

      Clearance.with("intimate") do
        decider = Principal.find_by!(name: args[:principal].presence || "jenner")
        row = Sentinel.decide!(SentinelRequest.find(args[:id]), decision: args[:decision], decider: decider, rationale: ENV["RATIONALE"],
                               fabricated: ENV["FABRICATED"] == "1")
        puts "#{row.id}: #{row.status}#{row.error && " (#{row.error})"}"
      end
    end
  end
end

namespace :hob do
  namespace :surface do
    desc "Register the capabilities a surface offers the sentinel (SENTINEL.md) from its manifest at /hob/capabilities, " \
         "and hand it the secret hob signs deliveries with. bin/rails \"hob:surface:register[mise,https://mise.example.com]\" " \
         "APP=<coolify app uuid> (RESTART=0 to skip the restart; no APP prints the secret once, for you to set as HOB_WEBHOOK_SECRET)"
    task :register, [ :surface, :url ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:surface:register[surface,url]\" APP=<coolify app uuid>" if args[:surface].blank? || args[:url].blank?

      result = SurfaceCapabilities.new.call(surface: args[:surface], url: args[:url], app: ENV["APP"].presence,
                                            restart: ENV["RESTART"] != "0", secret: ENV["SECRET"].presence)
      puts "#{result.surface}: #{result.created} capability(ies) registered, #{result.updated} updated, #{result.disabled} disabled"
      if result.pushed
        puts "#{SurfaceCapabilities::SECRET_ENV} set on #{ENV['APP']}; #{result.restarted ? 'restart queued' : 'not restarted'}"
      else
        puts "set on the surface (shown once): #{SurfaceCapabilities::SECRET_ENV}=#{result.secret}"
      end
      SurfaceCapabilities.registered(result.surface).each do |cap|
        puts "  #{cap.name.ljust(30)} #{cap.kind.ljust(5)} #{cap.realm.ljust(10)} #{cap.enabled ? '' : 'disabled'}"
      end
      puts "then let agents at them: bin/rails \"hob:sentinel:policy[marley,#{result.surface}.*,review]\" (README.md has a set)"
    end

    desc "List the capabilities registered for a surface: bin/rails \"hob:surface:capabilities[mise]\""
    task :capabilities, [ :surface ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:surface:capabilities[surface]\"" if args[:surface].blank?

      caps = SurfaceCapabilities.registered(args[:surface])
      puts "nothing registered for #{args[:surface]}; bin/rails \"hob:surface:register[#{args[:surface]},url]\"" if caps.empty?
      caps.each do |cap|
        requests = cap.sentinel_requests.count
        puts "#{cap.name.ljust(30)} #{cap.kind.ljust(5)} #{cap.realm.ljust(10)} #{cap.enabled ? 'enabled ' : 'disabled'} " \
             "#{requests} request(s)  #{cap.config['url']}"
      end
    end
  end
end

namespace :hob do
  namespace :capabilities do
    desc "Upsert the Capability rows for the native handlers in code (runs at boot; a merged forge PR lands here)"
    task sync: :environment do
      Clearance.with("intimate") do
        rows = Sentinel::Native.sync!
        puts "#{rows.size} native capabilities in sync: #{rows.map(&:name).join(', ')}"
      end
    end
  end

  namespace :forge do
    desc "Set up the forge worker (SENTINEL.md): the principal build missions go to, and its key, shown once. " \
         "bin/rails \"hob:forge:setup[forge]\" (re-running rotates the key)"
    task :setup, [ :name ] => :environment do |_task, args|
      name = args[:name].presence || ENV.fetch("HOB_FORGE_PRINCIPAL", "forge")
      forge = Principal.find_or_create_by!(name: name) { |p| p.kind = "worker"; p.max_clearance = "intimate" }
      abort "#{forge.name} is a #{forge.kind}, not a worker" unless forge.kind == "worker"

      token = ApiKey.issue!(principal: forge, surface: name, default_clearance: "intimate")
      rotated = forge.api_keys.where(surface: name).where.not(token_digest: ApiKey.digest(token)).destroy_all.size
      puts "#{forge.name}: worker key (shown once): #{token}"
      puts "rotated #{rotated} old key(s). For the forge service (Dockerfile.forge): HOB_URL= HOB_KEY=<key> CODER_URL= CODER_SESSION_TOKEN= bin/forge --coder"
    end
  end
end

namespace :hob do
  desc "Set a model's price in USD per million tokens and reprice the ledger. " \
       "bin/rails \"hob:price[claude-opus-5,5,25]\" CACHE_READ= CACHE_WRITE= NOTE='Anthropic list 2026-06' FROM=2026-06-01 REPRICE=0"
  task :price, [ :model, :input, :output ] => :environment do |_task, args|
    abort "usage: bin/rails \"hob:price[model,input_per_million,output_per_million]\"" if args[:output].blank?

    row = ModelPrice.set!(model: args[:model], input: args[:input].to_d, output: args[:output].to_d,
                          cache_read: ENV["CACHE_READ"].presence&.to_d, cache_write: ENV["CACHE_WRITE"].presence&.to_d,
                          note: ENV["NOTE"].presence, effective_from: ENV["FROM"].presence, reprice: ENV["REPRICE"] != "0")
    puts "#{row.model}: in $#{row.input.to_f} out $#{row.output.to_f} cache read $#{row.cache_read.to_f} write $#{row.cache_write.to_f}" \
         " per million; repriced #{row.repriced} ledger row(s)"
  end

  desc "List model prices and the models the ledger has seen without one"
  task prices: :environment do
    ModelPrice.order(:model).each do |p|
      puts "#{p.model.ljust(32)} in $#{format('%6.2f', p.input)}  out $#{format('%6.2f', p.output)}  cache $#{format('%.3f', p.cache_read)}/$#{format('%.3f', p.cache_write)}" \
           "#{p.note && "  (#{p.note}#{p.effective_from && ", from #{p.effective_from}"})"}"
    end
    unpriced = ModelPrice.unpriced_models
    puts unpriced.empty? ? "every model in the ledger is priced" : "unpriced in the ledger: #{unpriced.join(', ')}"
  end
end

namespace :hob do
  namespace :todos do
    desc "Register (or update) a todo backend (TODOS.md): where somebody's todos live. " \
         "bin/rails \"hob:todos:backend[jenner-omnifocus,omnifocus,http://mini.tailnet.ts.net:8377,personal]\" KEY_ENV=TALLY_KEY " \
         "(or KEY=<the key itself>) OWNER=jenner PRIMARY=1 ADDR=100.64.0.7 ENABLED=0"
    task :backend, [ :name, :kind, :url, :realm ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:todos:backend[name,kind=omnifocus,url,realm=personal]\" KEY_ENV= | KEY=" if args[:name].blank?

      Clearance.with("intimate") do
        row = TodoBackend.find_or_initialize_by(name: args[:name])
        row.kind = args[:kind].presence || row.kind || "omnifocus"
        row.realm = args[:realm].presence || row.realm || "personal"
        row.principal = Principal.find_by!(name: ENV["OWNER"]) if ENV["OWNER"].present?
        row.principal ||= Principal.find_by!(name: "jenner")
        config = row.config.dup
        config["url"] = args[:url] if args[:url].present?
        config = config.except("key", "key_env").merge("key_env" => ENV["KEY_ENV"]) if ENV["KEY_ENV"].present?
        config = config.except("key", "key_env").merge("key" => ENV["KEY"]) if ENV["KEY"].present?
        config["addr"] = ENV["ADDR"].presence if ENV.key?("ADDR")
        row.config = config.compact
        row.primary = ENV["PRIMARY"] == "1" if ENV.key?("PRIMARY")
        row.enabled = ENV["ENABLED"] != "0" if ENV.key?("ENABLED")
        created = row.new_record?
        row.save!
        puts "#{row.name}: #{created ? 'registered' : 'updated'}; #{row.kind} at #{row.url}, realm #{row.realm}, owner #{row.principal.name}" \
             "#{row.primary? ? ', primary' : ''}#{row.enabled? ? '' : ', disabled'}; " \
             "key #{row.config['key_env'].present? ? "from #{row.config['key_env']}#{row.key.blank? ? ' (not set in this environment)' : ''}" : 'stored in the row'}"
        puts "check it: bin/rails \"hob:todos:check[#{row.name}]\""
      end
    end

    desc "List todo backends and whether each answers"
    task backends: :environment do
      Clearance.with("intimate") do
        rows = TodoBackend.includes(:principal).order(:name)
        puts "no todo backends; bin/rails \"hob:todos:backend[name,omnifocus,url,realm]\" KEY_ENV=" if rows.empty?
        rows.each do |row|
          state = "disabled" unless row.enabled?
          state ||= begin
            row.adapter.check && "reachable"
          rescue Todos::Error => e
            "unreachable: #{e.message}"
          end
          puts "#{row.name.ljust(24)} #{row.kind.ljust(10)} #{row.realm.ljust(10)} #{row.principal.name.ljust(10)} " \
               "#{row.primary? ? 'primary' : '       '}  #{row.url}  #{state}"
        end
      end
    end

    desc "Ask one todo backend how it is: bin/rails \"hob:todos:check[jenner-omnifocus]\""
    task :check, [ :name ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:todos:check[name]\"" if args[:name].blank?

      Clearance.with("intimate") do
        row = TodoBackend.find_by!(name: args[:name])
        begin
          status = row.adapter.check
          puts "#{row.name}: reachable at #{row.url}"
          status.except("reachable").each { |name, value| puts "  #{name}: #{value.is_a?(String) ? value : value.to_json}" }
        rescue Todos::Error => e
          abort "#{row.name}: #{e.class.name.demodulize.downcase}: #{e.message}"
        end
      end
    end
  end
end

# Budgets (BUDGET.md): where the household's books are kept.
namespace :hob do
  namespace :budget do
    desc "List the YNAB plans a token can see, to choose one for hob:budget:backend: bin/rails hob:budget:plans KEY_ENV=YNAB_TOKEN"
    task plans: :environment do
      key = ENV[ENV["KEY_ENV"].presence || "YNAB_TOKEN"]
      abort "usage: bin/rails hob:budget:plans KEY_ENV=YNAB_TOKEN (the env var holding a YNAB personal access token)" if key.blank?

      begin
        Budgets::Backends::Ynab.plans(key).each do |plan|
          puts "#{plan['id']}  #{plan['name'].to_s.ljust(28)} #{plan['currency'].to_s.ljust(4)} last modified #{plan['last_modified_on']}"
        end
      rescue Budgets::Error => e
        abort "#{e.class.name.demodulize.downcase}: #{e.message}"
      end
    end

    desc "Register (or update) a budget backend (BUDGET.md): where somebody's budget is kept. " \
         "bin/rails \"hob:budget:backend[house-ynab,ynab,<plan id>,household]\" KEY_ENV=YNAB_TOKEN " \
         "(or KEY=<the token itself>) OWNER=jenner TIME_ZONE=America/Los_Angeles ENABLED=0"
    task :backend, [ :name, :kind, :plan, :realm ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:budget:backend[name,kind=ynab,plan,realm=personal]\" KEY_ENV= | KEY=" if args[:name].blank?

      Clearance.with("intimate") do
        row = BudgetBackend.find_or_initialize_by(name: args[:name])
        row.kind = args[:kind].presence || row.kind || "ynab"
        row.realm = args[:realm].presence || row.realm || "personal"
        row.principal = Principal.find_by!(name: ENV["OWNER"]) if ENV["OWNER"].present?
        row.principal ||= Principal.find_by!(name: "jenner")
        config = row.config.dup
        config["plan"] = args[:plan] if args[:plan].present?
        config = config.except("key", "key_env").merge("key_env" => ENV["KEY_ENV"]) if ENV["KEY_ENV"].present?
        config = config.except("key", "key_env").merge("key" => ENV["KEY"]) if ENV["KEY"].present?
        config["time_zone"] = ENV["TIME_ZONE"].presence if ENV.key?("TIME_ZONE")
        row.config = config.compact
        row.enabled = ENV["ENABLED"] != "0" if ENV.key?("ENABLED")
        created = row.new_record?
        row.save!
        puts "#{row.name}: #{created ? 'registered' : 'updated'}; #{row.kind} plan #{row.config['plan']}, realm #{row.realm}, " \
             "owner #{row.principal.name}, today in #{row.time_zone.name}#{row.enabled? ? '' : ', disabled'}; " \
             "key #{row.config['key_env'].present? ? "from #{row.config['key_env']}#{row.key.blank? ? ' (not set in this environment)' : ''}" : 'stored in the row'}"
        puts "check it: bin/rails \"hob:budget:check[#{row.name}]\""
      end
    end

    desc "List budget backends and whether each answers"
    task backends: :environment do
      Clearance.with("intimate") do
        rows = BudgetBackend.includes(:principal).order(:name)
        puts "no budget backends; bin/rails \"hob:budget:backend[name,ynab,plan,realm]\" KEY_ENV=" if rows.empty?
        rows.each do |row|
          state = "disabled" unless row.enabled?
          state ||= begin
            row.adapter.check && "reachable"
          rescue Budgets::Error => e
            "unreachable: #{e.message}"
          end
          puts "#{row.name.ljust(24)} #{row.kind.ljust(10)} #{row.realm.ljust(10)} #{row.principal.name.ljust(10)} #{row.config['plan']}  #{state}"
        end
      end
    end

    desc "Ask one budget backend how it is: bin/rails \"hob:budget:check[house-ynab]\""
    task :check, [ :name ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:budget:check[name]\"" if args[:name].blank?

      Clearance.with("intimate") do
        row = BudgetBackend.find_by!(name: args[:name])
        begin
          status = row.adapter.check
          puts "#{row.name}: reachable"
          status.except("reachable").each { |name, value| puts "  #{name}: #{value.is_a?(String) ? value : value.to_json}" }
        rescue Budgets::Error => e
          abort "#{row.name}: #{e.class.name.demodulize.downcase}: #{e.message}"
        end
      end
    end
  end
end

# The ward (WARD.md): the household's security watch.
namespace :hob do
  namespace :ward do
    desc "Set up the ward worker: the principal that posts reports and leases ward.audit missions, and its key, shown once. " \
         "bin/rails \"hob:ward:setup[ward]\" (re-running rotates the key)"
    task :setup, [ :name ] => :environment do |_task, args|
      name = args[:name].presence || ENV.fetch("HOB_WARD_PRINCIPAL", "ward")
      ward = Principal.find_or_create_by!(name: name) { |p| p.kind = "worker"; p.max_clearance = "personal" }
      abort "#{ward.name} is a #{ward.kind}, not a worker" unless ward.kind == "worker"

      token = ApiKey.issue!(principal: ward, surface: name, default_clearance: "personal")
      rotated = ward.api_keys.where(surface: name).where.not(token_digest: ApiKey.digest(token)).destroy_all.size
      check = WardCheck.find_or_create_by!(slug: "exposure") do |c|
        c.description = "infra security/audit.py: Coolify inventory, routes, Authelia gates, full TCP exposure"
      end
      schedule = Clearance.with("intimate") { Ward.schedule!(check, worker: ward, cron: ENV.fetch("CRON", "0 4 * * 1")) }
      puts "#{ward.name}: worker key (shown once): #{token}"
      puts "rotated #{rotated} old key(s). Checks: #{WardCheck.order(:slug).pluck(:slug).join(', ')}; " \
           "#{schedule.name} fires #{schedule.cron} (#{schedule.time_zone}), next #{schedule.next_fire_at&.utc&.iso8601}"
      puts "On the runner: HOB_URL=https://... HOB_KEY=<key> COOLIFY_BASE_URL= COOLIFY_API_TOKEN=<read-only> python3 security/ward.py work"
    end

    desc "Run a check on hob's clock: a ward.audit mission for the worker on a cron line. " \
         "bin/rails \"hob:ward:schedule[exposure]\" CRON='0 4 * * 1' TZ_NAME=America/Los_Angeles (the worker then runs `work` without --every)"
    task :schedule, [ :slug ] => :environment do |_task, args|
      check = WardCheck.find(args[:slug].presence || "exposure")
      worker = Principal.find_by!(name: ENV.fetch("HOB_WARD_PRINCIPAL", "ward"), kind: "worker")
      Clearance.with("intimate") do
        schedule = Ward.schedule!(check, worker: worker, cron: ENV.fetch("CRON", "0 4 * * 1"),
                                  time_zone: ENV["TZ_NAME"].presence || ENV.fetch("HOB_TIME_ZONE", "Etc/UTC"))
        puts "#{schedule.name}: #{schedule.cron} (#{schedule.time_zone}) → #{worker.name}, next #{schedule.next_fire_at&.utc&.iso8601 || 'never (disabled)'}"
      end
    end

    desc "Register or retune a check. bin/rails \"hob:ward:check[exposure,7,1]\" (slug, interval days, grace days) DESCRIPTION= ENABLED=0|1"
    task :check, [ :slug, :interval_days, :grace_days ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:ward:check[slug,interval_days,grace_days]\"" if args[:slug].blank?

      check = WardCheck.find_or_initialize_by(slug: args[:slug])
      check.interval_seconds = (args[:interval_days].to_f * 86_400).to_i if args[:interval_days].present?
      check.grace_seconds = (args[:grace_days].to_f * 86_400).to_i if args[:grace_days].present?
      check.description = ENV["DESCRIPTION"] if ENV.key?("DESCRIPTION")
      check.enabled = ENV["ENABLED"] != "0" if ENV.key?("ENABLED")
      check.save!
      puts "#{check.slug}: every #{check.interval_seconds}s, grace #{check.grace_seconds}s, #{check.enabled? ? 'enabled' : 'disabled'}"
    end

    desc "The ward's picture: checks, staleness, open and acknowledged findings, the latest triage"
    task status: :environment do
      Clearance.with("intimate") do
        status = Ward.status
        status["checks"].each do |c|
          last = c["last_run"]
          puts "#{c['slug'].ljust(12)} #{c['stale'] ? 'STALE  ' : 'ok     '} last complete #{c['last_completed_at'] || 'never'}; " \
               "#{last ? "last run #{last['at']} exit #{last['exit_code'].inspect} (#{last['summary']})" : 'no runs'}; " \
               "open #{c['open']}, acknowledged #{c['acknowledged']}"
        end
        puts "checks: none registered (bin/rails \"hob:ward:check[exposure,7,1]\")" if status["checks"].empty?
        puts "\nopen:"
        puts "  (none)" if status["open"].empty?
        status["open"].each { |f| puts "  #{f['id']}  [#{f['level'].upcase}] #{f['message']}  (#{f['occurrences']}×, since #{f['first_seen_at']})" }
        puts "\nacknowledged:"
        puts "  (none)" if status["acknowledged"].empty?
        status["acknowledged"].each { |f| puts "  #{f['id']}  [#{f['level'].upcase}] #{f['message']}  — #{f['acknowledged_by']}: #{f['ack_note']}#{f['ack_until'] && " until #{f['ack_until']}"}" }
        if (t = status["triage"])
          puts "\nlatest triage (#{t['at']}, run #{t['run']}): #{t['severity']} — #{t['headline']}"
          puts "  #{t['summary']}" if t["summary"]
          Array(t["next_steps"]).each_with_index { |s, i| puts "  #{i + 1}. #{s}" }
          puts "  error: #{t['error']}" if t["error"]
        end
      end
    end

    desc "List findings by state. bin/rails \"hob:ward:findings[open|acknowledged|resolved|all]\" CHECK="
    task :findings, [ :state ] => :environment do |_task, args|
      Clearance.with("intimate") do
        Ward::Sweep.call
        rows = WardFinding.in_state(args[:state].presence || "open").by_severity
        rows = rows.where(check_slug: ENV["CHECK"]) if ENV["CHECK"].present?
        puts "no findings" if rows.empty?
        rows.each do |f|
          puts "#{f.id}  #{f.state.ljust(12)} [#{f.level.upcase}] #{f.check_slug}: #{f.message}"
          puts "  first #{f.first_seen_at.utc.iso8601}, last #{f.last_seen_at.utc.iso8601}, #{f.occurrences}×#{f.resolved_at && ", resolved #{f.resolved_at.utc.iso8601}"}"
          puts "  acknowledged by #{f.acknowledged_by&.name}: #{f.ack_note}#{f.ack_until && " until #{f.ack_until.utc.iso8601}"}" if f.acknowledged_at
        end
      end
    end

    desc "Acknowledge a finding as a person. bin/rails \"hob:ward:ack[<id>,jenner]\" NOTE='reviewed: intentional' UNTIL=2026-12-01"
    task :ack, [ :id, :principal ] => :environment do |_task, args|
      Clearance.with("intimate") do
        person = Principal.find_by!(name: args[:principal].presence || ENV.fetch("HOB_PERSON", "jenner"))
        abort "#{person.name} is not a person" unless person.trusted?
        finding = WardFinding.find(args[:id])
        finding.acknowledge!(by: person, note: ENV["NOTE"], until_at: ENV["UNTIL"].presence && Time.zone.parse(ENV["UNTIL"]))
        puts "#{finding.id} acknowledged by #{person.name}#{finding.ack_until && " until #{finding.ack_until.utc.iso8601}"}: #{finding.message}"
      end
    end

    desc "Withdraw an acknowledgement. bin/rails \"hob:ward:unack[<id>]\""
    task :unack, [ :id ] => :environment do |_task, args|
      finding = WardFinding.find(args[:id])
      finding.unacknowledge!
      puts "#{finding.id} is open again: #{finding.message}"
    end

    desc "Attach a note to a subject (a host, a resource, a check). bin/rails \"hob:ward:note[vaultwarden,jenner]\" BODY='...'"
    task :note, [ :subject, :principal ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:ward:note[subject,person]\" BODY='...'" if args[:subject].blank? || ENV["BODY"].blank?

      person = Principal.find_by!(name: args[:principal].presence || ENV.fetch("HOB_PERSON", "jenner"))
      note = WardNote.create!(subject: args[:subject], body: ENV["BODY"], author: person)
      puts "#{note.id} on #{note.subject}: #{note.body}"
    end

    desc "List notes. bin/rails \"hob:ward:notes[subject]\""
    task :notes, [ :subject ] => :environment do |_task, args|
      rows = WardNote.recent
      rows = rows.about(args[:subject]) if args[:subject].present?
      puts "no notes" if rows.empty?
      rows.each { |n| puts "#{n.created_at.utc.to_date}  #{n.subject}  (#{n.author&.name}): #{n.body}" }
    end

    desc "List runs. bin/rails \"hob:ward:runs[exposure,20]\""
    task :runs, [ :check, :limit ] => :environment do |_task, args|
      rows = WardRun.recent.limit((args[:limit].presence || 20).to_i)
      rows = rows.where(check_slug: args[:check]) if args[:check].present?
      puts "no runs" if rows.empty?
      rows.each do |r|
        puts "#{r.id}  #{r.created_at.utc.iso8601}  #{r.mechanical_summary}#{r.triage_headline && "  → #{r.triage['severity']}: #{r.triage_headline}"}"
      end
    end

    desc "The ward's clock: raise stale checks, expire acknowledgements, triage what changed, then the threats' upkeep " \
         "(inventory, resolver). WardSweepJob runs it hourly; this is by hand."
    task sweep: :environment do
      Clearance.with("intimate") do
        Current.set(surface: Ward::SURFACE) do
          run = Ward::Sweep.call
          puts run ? "sweep: #{run.mechanical_summary}" : "sweep: nothing changed"
          upkeep = Ward.threat_upkeep!
          puts "inventory: #{upkeep['inventory'].to_json}" if upkeep["inventory"]
          upkeep["threats"].each { |id, what| puts "threat #{id}: #{what}" }
        end
      end
    end

    # Threats (THREATS.md): what the ward is told, and a person's decisions on them.
    namespace :threat do
      ward_person = lambda do
        person = Principal.find_by!(name: ENV.fetch("HOB_PERSON", "jenner"))
        abort "#{person.name} is not a person" unless person.trusted?
        person
      end
      ward_threat = lambda do |id|
        abort "usage: give the threat's id (bin/rails hob:ward:threat:list)" if id.blank?
        WardThreat.find(id)
      end
      ward_print = lambda do |threat|
        puts "#{threat.id}  #{threat.kind}  #{threat.status}  #{threat.assessed_severity || '-'}#{" (#{threat.confidence})" if threat.confidence}  #{threat.title}"
        puts "  cves: #{threat.cve_ids.join(', ')}" if threat.cve_ids.any?
        puts "  component: #{threat.component}, fixed: #{threat.fixed_versions.map { |b, v| "#{b}→#{v}" }.join(', ').presence || 'unknown'}" if threat.component
        puts "  actor: #{threat.actor}#{" on #{threat.target}" if threat.target}, window until #{threat.expires_at&.utc&.iso8601}" if threat.actor?
        threat.affected.each { |a| puts "  - #{[ a['name'], a['component'], a['version'], a['verdict'], a['exposure'], a['why'], a['disagreement'] ].compact.join(' · ')}" }
        threat.gotchas.each_with_index { |g, i| puts "  gotcha #{i}: #{g['text']}#{g['satisfied_at'] ? " ✓ #{g['satisfied_by']}: #{g['evidence']}" : ' (open)'}" }
        threat.pending_proposals.each { |p| puts "  proposal #{p['id']} (tier #{p['tier'] || 'person'}): #{p['title']} — #{p['detail']} [blast radius: #{p['blast_radius']}]" }
        puts "  upstream: #{threat.upstream.to_json}" if threat.upstream
        puts "  resolution: #{threat.resolution['criteria']} (#{threat.resolution['verified_by']}, #{threat.resolution['resolved_at']})" if threat.resolution
        puts "  accepted by #{threat.accepted_by&.name}: #{threat.accepted_reason}; review #{threat.review_at&.utc&.to_date}" if threat.status == "accepted_risk"
      end

      desc "List threats. bin/rails \"hob:ward:threat:list[open|closed|all|<status>]\""
      task :list, [ :state ] => :environment do |_task, args|
        rows = WardThreat.in_state(args[:state]).by_severity
        puts "no threats" if rows.empty?
        rows.each { |t| puts "#{t.id}  #{t.status.ljust(17)} #{(t.assessed_severity || '-').ljust(8)} #{t.kind.ljust(8)} #{t.title}" }
      end

      desc "One threat and its history. bin/rails \"hob:ward:threat:show[<id>]\""
      task :show, [ :id ] => :environment do |_task, args|
        threat = ward_threat.call(args[:id])
        ward_print.call(threat)
        puts "\nhistory:"
        threat.events.includes(:principal).each do |e|
          puts "  #{e.created_at.utc.iso8601}  #{e.kind.ljust(10)} #{e.principal&.name || 'ward'}#{" #{e.from_status}→#{e.to_status}" if e.to_status}: #{e.body}"
        end
      end

      desc "Report a threat as a person. bin/rails hob:ward:threat:report KIND=cve TITLE='PHP2Shell RCE in PHP core' " \
           "CVES=CVE-2026-109618,CVE-2026-109619 COMPONENT=php FIXED='8.3=8.3.36,8.4=8.4.27' GOTCHAS='FPM workers restarted after the patch' " \
           "SEVERITY=critical EXPLOITED=1 SOURCE='https://...'  ·  KIND=actor ACTOR=handle TARGET=hob WINDOW_DAYS=7"
      task report: :environment do
        Clearance.with("intimate") do
          Current.set(surface: Ward::SURFACE) do
            fixed = ENV["FIXED"].to_s.split(",").to_h { |pair| pair.split("=", 2).map(&:strip) }.compact_blank
            attributes = {
              "kind" => ENV["KIND"], "title" => ENV["TITLE"], "cve_ids" => ENV["CVES"].to_s.split(","), "component" => ENV["COMPONENT"],
              "fixed_versions" => fixed.presence, "gotchas" => ENV["GOTCHAS"].to_s.split("|").presence, "claimed_severity" => ENV["SEVERITY"],
              "exploited" => ENV["EXPLOITED"] == "1" || nil, "source" => ENV["SOURCE"].presence && { "ref" => ENV["SOURCE"] },
              "actor" => ENV["ACTOR"], "target" => ENV["TARGET"], "window_days" => ENV["WINDOW_DAYS"]
            }.compact_blank
            threat, merged = Ward::Threats.report!(attributes, by: ward_person.call)
            puts merged ? "merged into an open threat:" : "reported:"
            ward_print.call(threat)
          end
        end
      rescue Ward::Invalid => e
        abort e.message
      end

      desc "Add a note to a threat. bin/rails \"hob:ward:threat:note[<id>]\" BODY='...' EVIDENCE= INDICATOR=1"
      task :note, [ :id ] => :environment do |_task, args|
        Clearance.with("intimate") do
          threat = ward_threat.call(args[:id])
          Ward::Threats.note!(threat, body: ENV["BODY"], by: ward_person.call, evidence: ENV["EVIDENCE"], indicator: ENV["INDICATOR"] == "1")
          puts "#{threat.id}: noted"
        end
      end

      desc "Match a threat against the inventory again. bin/rails \"hob:ward:threat:retriage[<id>]\""
      task :retriage, [ :id ] => :environment do |_task, args|
        Clearance.with("intimate") { ward_print.call(Ward::Threats.triage!(ward_threat.call(args[:id]), by: ward_person.call)) }
      end

      desc "Accept a threat as a known risk. bin/rails \"hob:ward:threat:accept[<id>]\" REASON='...' REVIEW_DAYS=30"
      task :accept, [ :id ] => :environment do |_task, args|
        Clearance.with("intimate") do
          ward_print.call(Ward::Threats.accept_risk!(ward_threat.call(args[:id]), reason: ENV["REASON"], by: ward_person.call, review_days: ENV["REVIEW_DAYS"]))
        end
      end

      desc "End an actor watch early. bin/rails \"hob:ward:threat:standdown[<id>]\" REASON='...'"
      task :standdown, [ :id ] => :environment do |_task, args|
        Clearance.with("intimate") { ward_print.call(Ward::Threats.standdown!(ward_threat.call(args[:id]), reason: ENV["REASON"], by: ward_person.call)) }
      end

      desc "Wait for the fix upstream, and watch for it. bin/rails \"hob:ward:threat:await[<id>]\" SOURCE=github|dockerhub " \
           "REPOSITORY=coollabsio/coolify CURRENT=4.0.0-beta.420 FIXED= POLL_HOURS=6"
      task :await, [ :id ] => :environment do |_task, args|
        Clearance.with("intimate") do
          spec = { "source" => ENV["SOURCE"], "repository" => ENV["REPOSITORY"], "current" => ENV["CURRENT"], "fixed" => ENV["FIXED"], "poll_hours" => ENV["POLL_HOURS"] }
          ward_print.call(Ward::Threats.await_upstream!(ward_threat.call(args[:id]), upstream: spec.compact_blank, by: ward_person.call))
        end
      end

      desc "Keep an actor watch going: another window from now. bin/rails \"hob:ward:threat:extend[<id>,7]\""
      task :extend, [ :id, :days ] => :environment do |_task, args|
        Clearance.with("intimate") { ward_print.call(Ward::Threats.extend!(ward_threat.call(args[:id]), by: ward_person.call, days: args[:days])) }
      end

      desc "Check off a gotcha. bin/rails \"hob:ward:threat:gotcha[<id>,0]\" EVIDENCE='php-fpm restarted 14:02, workers 8.3.36'"
      task :gotcha, [ :id, :index ] => :environment do |_task, args|
        Clearance.with("intimate") do
          threat = ward_threat.call(args[:id])
          Ward::Threats.satisfy!(threat, args[:index], evidence: ENV["EVIDENCE"], by: ward_person.call)
          ward_print.call(threat)
        end
      end

      desc "Confirm or decline what the ward proposed. bin/rails \"hob:ward:threat:decide[<id>,<proposal>,confirm|decline]\" NOTE="
      task :decide, [ :id, :proposal, :decision ] => :environment do |_task, args|
        Clearance.with("intimate") do
          Current.set(surface: Ward::SURFACE) do
            ward_print.call(Ward::Threats.decide!(ward_threat.call(args[:id]), args[:proposal], decision: args[:decision], by: ward_person.call, note: ENV["NOTE"]))
          end
        end
      end
    end

    # The inventory threats are matched against (THREATS.md, "Triage").
    namespace :inventory do
      desc "Pull the inventory from Coolify with the ward's read-only token (HOB_WARD_COOLIFY_TOKEN). bin/rails hob:ward:inventory:sync"
      task sync: :environment do
        puts Ward::Inventory.sync!.to_json
      rescue Ward::Error => e
        abort e.message
      end

      desc "What the ward knows the household runs. bin/rails hob:ward:inventory:assets ALL=1"
      task assets: :environment do
        rows = WardAsset.by_name
        rows = rows.present unless ENV["ALL"] == "1"
        puts "no assets (bin/rails hob:ward:inventory:sync)" if rows.empty?
        rows.each do |a|
          components = a.component_names.map { |c| "#{c} #{a.believed(c).first || '?'}" }.join(", ")
          puts "#{a.name.ljust(24)} #{a.kind.ljust(14)} #{(a.host || '-').ljust(10)} #{(a.effective_exposure || '-').ljust(9)} #{components}#{' (gone)' if a.gone_at}"
        end
      end

      desc "Record what a probe saw. bin/rails \"hob:ward:inventory:observe[coolify,php,8.3.36]\" STARTED_AT="
      task :observe, [ :asset, :component, :version ] => :environment do |_task, args|
        asset = WardAsset.find_by(ref: args[:asset]) || WardAsset.present.find_by!(name: args[:asset])
        person = Principal.find_by!(name: ENV.fetch("HOB_PERSON", "jenner"))
        observation = asset.observe!(component: args[:component], version: args[:version], source: "person", principal: person,
                                     started_at: ENV["STARTED_AT"].presence && Time.zone.parse(ENV["STARTED_AT"]))
        puts "#{asset.name}: #{observation.component} #{observation.version} (#{observation.source}, #{observation.last_seen_at.utc.iso8601})"
      end

      desc "Say what an asset runs or how exposed it is, over what the inventory implies. " \
           "bin/rails \"hob:ward:inventory:declare[coolify]\" COMPONENTS=php,laravel EXPOSURE=public|tailnet|localhost"
      task :declare, [ :asset ] => :environment do |_task, args|
        asset = WardAsset.find_by(ref: args[:asset]) || WardAsset.present.find_by(name: args[:asset]) ||
                WardAsset.create!(ref: "manual:#{args[:asset]}", name: args[:asset], kind: ENV.fetch("KIND", "application"), source: "person",
                                  host: ENV["HOST"], last_seen_at: Time.current)
        declared = asset.declared.dup
        declared["components"] = ENV["COMPONENTS"].split(",").filter_map { |c| WardAsset.component_name(c) } if ENV.key?("COMPONENTS")
        declared["exposure"] = ENV["EXPOSURE"].presence if ENV.key?("EXPOSURE")
        asset.update!(declared: declared.compact_blank)
        puts "#{asset.name}: #{asset.declared.to_json}"
      end
    end
  end
end

namespace :hob do
  namespace :browse do
    desc "Register (or update) a browser (BROWSE.md): a gofer on somebody's Mac. " \
         "bin/rails \"hob:browse:browser[mini-chrome,gofer,http://mini.tailnet.ts.net:8378,personal]\" KEY_ENV=GOFER_KEY " \
         "(or KEY=<the key itself>) OWNER=jenner ADDR=100.64.0.7 DOMAINS=amazon.com,ynab.com ENABLED=0"
    task :browser, [ :name, :kind, :url, :realm ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:browse:browser[name,kind=gofer,url,realm=personal]\" KEY_ENV= | KEY=" if args[:name].blank?

      Clearance.with("intimate") do
        row = Browser.find_or_initialize_by(name: args[:name])
        row.kind = args[:kind].presence || row.kind || "gofer"
        row.realm = args[:realm].presence || row.realm || "personal"
        row.principal = Principal.find_by!(name: ENV["OWNER"]) if ENV["OWNER"].present?
        row.principal ||= Principal.find_by!(name: "jenner")
        config = row.config.dup
        config["url"] = args[:url] if args[:url].present?
        config = config.except("key", "key_env").merge("key_env" => ENV["KEY_ENV"]) if ENV["KEY_ENV"].present?
        config = config.except("key", "key_env").merge("key" => ENV["KEY"]) if ENV["KEY"].present?
        config["addr"] = ENV["ADDR"].presence if ENV.key?("ADDR")
        config["domains"] = ENV["DOMAINS"].to_s.split(",").map(&:strip).reject(&:blank?).presence if ENV.key?("DOMAINS")
        row.config = config.compact
        row.enabled = ENV["ENABLED"] != "0" if ENV.key?("ENABLED")
        created = row.new_record?
        row.save!
        puts "#{row.name}: #{created ? 'registered' : 'updated'}; #{row.kind} at #{row.url}, realm #{row.realm}, owner #{row.principal.name}" \
             "#{row.domains.any? ? ", domains #{row.domains.join(', ')}" : ''}#{row.enabled? ? '' : ', disabled'}; " \
             "key #{row.config['key_env'].present? ? "from #{row.config['key_env']}#{row.key.blank? ? ' (not set in this environment)' : ''}" : 'stored in the row'}"
        puts "check it: bin/rails \"hob:browse:check[#{row.name}]\""
      end
    end

    desc "List browsers and whether each answers"
    task browsers: :environment do
      Clearance.with("intimate") do
        rows = Browser.includes(:principal).order(:name)
        puts "no browsers; bin/rails \"hob:browse:browser[name,gofer,url,realm]\" KEY_ENV=" if rows.empty?
        rows.each do |row|
          state = "disabled" unless row.enabled?
          state ||= begin
            status = row.adapter.check
            "reachable, #{status['sessions']} session(s) open"
          rescue Browse::Error => e
            "unreachable: #{e.message}"
          end
          puts "#{row.name.ljust(24)} #{row.kind.ljust(8)} #{row.realm.ljust(10)} #{row.principal.name.ljust(10)} #{row.url}  #{state}"
        end
      end
    end

    desc "Ask one browser how it is: bin/rails \"hob:browse:check[mini-chrome]\""
    task :check, [ :name ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:browse:check[name]\"" if args[:name].blank?

      Clearance.with("intimate") do
        row = Browser.find_by!(name: args[:name])
        begin
          status = row.adapter.check
          puts "#{row.name}: reachable at #{row.url}"
          status.except("reachable").each { |name, value| puts "  #{name}: #{value.is_a?(String) ? value : value.to_json}" }
        rescue Browse::Error => e
          abort "#{row.name}: #{e.class.name.demodulize.downcase}: #{e.message}"
        end
      end
    end

    desc "Open sessions, and who has them"
    task sessions: :environment do
      Clearance.with("intimate") do
        rows = BrowseSession.open.includes(:browser, :principal).order(:created_at)
        puts "no open sessions" if rows.empty?
        rows.each do |row|
          puts "#{row.id}  #{row.browser.name.ljust(16)} #{row.principal.name.ljust(10)} #{row.steps.to_s.rjust(3)} steps  #{row.url}\n    #{row.goal}"
        end
      end
    end
  end
end

# Records (RECORDS.md): what the household's agents keep.
namespace :hob do
  namespace :records do
    desc "Make (or change) a record collection as a person. bin/rails \"hob:records:collection[amazon-orders,household,order_id]\" " \
         "OWNER=jenner SCHEMA=path/to/schema.json (SCHEMA=none drops it) DESCRIPTION='...'"
    task :collection, [ :name, :realm, :key ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:records:collection[name,realm,key]\" DESCRIPTION= SCHEMA= OWNER=" if args[:name].blank?

      Clearance.with("intimate") do
        Current.set(clearance: "intimate") do
          schema = case ENV["SCHEMA"]
          when nil then :unset
          when "none", "" then nil
          else JSON.parse(File.read(ENV["SCHEMA"]))
          end
          existing = RecordCollection.find_by(name: args[:name])
          begin
            if existing
              abort "#{existing.name} is retracted; restore it in /admin/records first" if existing.retracted?
              attrs = { "collection" => existing.name, "reason" => "changed from a terminal" }
              attrs["description"] = ENV["DESCRIPTION"] if ENV["DESCRIPTION"].present?
              attrs["schema"] = schema unless schema == :unset
              result = Records.update_collection(attrs)
              row = result["collection"]
              puts "#{row['name']}: #{result['changed'] ? 'updated' : 'unchanged'}; schema version #{row['schema_version']}" \
                   "#{result['refused'].positive? ? ", #{result['refused']} current records the schema would refuse (hob:records:check)" : ''}"
            else
              owner = Principal.find_by!(name: ENV["OWNER"].presence || "jenner")
              abort "usage: DESCRIPTION='what it holds and why' is required for a new collection" if ENV["DESCRIPTION"].blank?
              row = Records.create_collection(
                { "name" => args[:name], "realm" => args[:realm].presence || "household", "key" => args[:key],
                  "description" => ENV["DESCRIPTION"], "schema" => schema == :unset ? nil : schema }, owner: owner
              )
              puts "#{row.name}: made; realm #{row.realm}, key #{row.key_path}, owner #{row.principal.name}, " \
                   "#{row.schema ? 'with a schema' : 'no schema'}"
            end
          rescue Records::Error => e
            abort "#{e.class.name.demodulize.downcase}: #{e.message}"
          end
        end
      end
    end

    desc "List record collections: realm, owner, key, schema version, how many records, last write"
    task collections: :environment do
      Clearance.with("intimate") do
        rows = RecordCollection.includes(:principal, :proposed_by).order(:name)
        puts "no record collections; bin/rails \"hob:records:collection[name,realm,key]\" DESCRIPTION=" if rows.empty?
        rows.each do |row|
          live = row.records.live
          puts "#{row.name.ljust(24)} #{row.realm.ljust(10)} #{row.principal.name.ljust(10)} key #{row.key_path.ljust(14)} " \
               "schema v#{row.schema_version}#{row.schema ? '' : ' (none)'}  #{live.count} records, last #{live.maximum(:updated_at)&.utc&.iso8601 || 'never'}" \
               "#{row.proposed_by ? "  (asked for by #{row.proposed_by.name})" : ''}#{row.retracted? ? '  RETRACTED' : ''}"
        end
      end
    end

    desc "List the current records a collection's schema would now refuse: bin/rails \"hob:records:check[amazon-orders]\""
    task :check, [ :name ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:records:check[name]\"" if args[:name].blank?

      Clearance.with("intimate") do
        collection = RecordCollection.find_by!(name: args[:name])
        refused = Records.refusals(collection)
        puts "#{collection.name}: every current record meets schema version #{collection.schema_version}" if refused.empty?
        refused.each { |record, problems| puts "#{record.ref} (v#{record.version}, schema v#{record.schema_version}): #{problems.join('; ')}" }
      end
    end
  end
end

namespace :hob do
  namespace :schedules do
    desc "Create or retime a schedule hob owns (SCHEDULES.md). bin/rails \"hob:schedules:set[name,0 7 * * *,assignee]\" " \
         "TITLE= BRIEF= PAYLOAD='{\"kind\":...}' REALM=household TZ_NAME=America/Los_Angeles PRIORITY=0 DESCRIPTION= ENABLED=0|1"
    task :set, [ :name, :cron, :assignee ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:schedules:set[name,cron,assignee]\" TITLE=..." if args[:name].blank?

      Clearance.with("intimate") do
        schedule = Schedule.find_or_initialize_by(created_by: nil, name: args[:name])
        schedule.cron = args[:cron] if args[:cron].present?
        schedule.assignee = Principal.find_by!(name: args[:assignee]) if args[:assignee].present?
        schedule.title = ENV["TITLE"] if ENV.key?("TITLE")
        schedule.title ||= schedule.name
        schedule.brief = ENV["BRIEF"].presence if ENV.key?("BRIEF")
        schedule.payload = JSON.parse(ENV["PAYLOAD"]) if ENV.key?("PAYLOAD")
        schedule.realm = ENV["REALM"] if ENV.key?("REALM")
        schedule.realm ||= "household"
        schedule.time_zone = ENV["TZ_NAME"] if ENV.key?("TZ_NAME")
        schedule.time_zone = ENV.fetch("HOB_TIME_ZONE", "Etc/UTC") if schedule.new_record? && !ENV.key?("TZ_NAME")
        schedule.priority = ENV["PRIORITY"].to_i if ENV.key?("PRIORITY")
        schedule.description = ENV["DESCRIPTION"] if ENV.key?("DESCRIPTION")
        schedule.enabled = ENV["ENABLED"] != "0" if ENV.key?("ENABLED")
        abort schedule.errors.full_messages.to_sentence unless schedule.save

        puts "#{schedule.name}: #{schedule.cron} (#{schedule.time_zone}) → #{schedule.assignee.name}, " \
             "next #{schedule.next_fire_at&.utc&.iso8601 || 'never (disabled)'}"
      end
    end

    desc "Every schedule: who made it, what it queues, when it fires next"
    task list: :environment do
      Clearance.with("intimate") do
        rows = Schedule.includes(:assignee, :created_by).order(:next_fire_at, :name)
        puts "no schedules" if rows.empty?
        rows.each do |s|
          state = s.enabled? ? "next #{s.next_fire_at&.utc&.iso8601}" : "disabled"
          skips = ", #{s.skipped_count} skipped" if s.skipped_count.positive?
          puts "#{s.name.ljust(28)} #{(s.created_by&.name || 'hob').ljust(10)} → #{s.assignee.name.ljust(10)} " \
               "#{s.cron} (#{s.time_zone})  #{state}  fired #{s.fired_count}#{skips}\n    #{s.title}"
        end
      end
    end

    desc "Delete a schedule: bin/rails \"hob:schedules:drop[name]\" (BY=<principal> for one an agent made)"
    task :drop, [ :name ] => :environment do |_task, args|
      Clearance.with("intimate") do
        by = ENV["BY"].presence && Principal.find_by!(name: ENV["BY"])
        Schedule.find_by!(created_by: by, name: args[:name]).destroy!
        puts "dropped #{args[:name]}"
      end
    end

    desc "Fire one schedule now, as if it were due: bin/rails \"hob:schedules:fire[name]\" (BY=<principal> for one an agent made). " \
         "Skipped, as always, while its last mission is open."
    task :fire, [ :name ] => :environment do |_task, args|
      Clearance.with("intimate") do
        by = ENV["BY"].presence && Principal.find_by!(name: ENV["BY"])
        schedule = Schedule.find_by!(created_by: by, name: args[:name])
        mission = schedule.fire!
        puts mission ? "#{schedule.name}: queued #{mission.id}" : "#{schedule.name}: skipped; #{schedule.last_mission_id} is still open"
      end
    end

    desc "Fire whatever is due now, as ScheduleTickJob does every minute (for when bin/jobs is not running)"
    task tick: :environment do
      fired = ScheduleTickJob.new.perform
      puts "nothing due" if fired.empty?
      fired.each { |schedule, mission| puts "#{schedule.name}: #{mission ? "queued #{mission.id}" : 'skipped, last mission still open'}" }
    end
  end
end

namespace :hob do
  namespace :upkeep do
    desc "Give every household repo on Coolify its upkeep schedules (SCHEDULES.md); UpkeepDiscoverJob does this weekly. DRY=1 to only show"
    task discover: :environment do
      Clearance.with("intimate") do
        report = Upkeep.discover!(dry_run: ENV["DRY"] == "1")
        puts "#{ENV['DRY'] == '1' ? '(dry run) ' : ''}repos: #{report.repos.join(', ').presence || 'none'} (owners #{Upkeep.owners.join(', ')})"
        %i[created updated disabled].each { |k| puts "#{k}: #{report[k].join(', ')}" if report[k].any? }
      end
    end

    desc "Read the kept repos' checks and queue a forge fix for each red branch (SCHEDULES.md); UpkeepChecksJob does this every 15 minutes. DRY=1 to only show"
    task checks: :environment do
      Clearance.with("intimate") do
        report = Upkeep::Checks.watch!(dry_run: ENV["DRY"] == "1")
        report.checked.sort.each { |repo, state| puts "#{repo}: #{state}" }
        report.errors.each { |repo, error| puts "#{repo}: could not read: #{error}" }
        puts "#{ENV['DRY'] == '1' ? '(dry run) would queue' : 'queued'} fixes: #{report.queued.join(', ')}" if report.queued.any?
      end
    end

    desc "Run a repo's upkeep now: bin/rails \"hob:upkeep:run[hob]\" or \"hob:upkeep:run[jenrzzz/hob,major]\""
    task :run, [ :repo, :scope ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:upkeep:run[repo,minor|major]\"" if args[:repo].blank?

      scope = args[:scope].presence || "minor"
      name = Clearance.with("intimate") { Upkeep.schedule_for(args[:repo], scope)&.name }
      abort "no #{scope} upkeep schedule for #{args[:repo]}; bin/rails hob:upkeep:discover" if name.nil?

      Rake::Task["hob:schedules:fire"].invoke(name)
    end
  end
end

# People (PEOPLE.md): who the household knows, and what is still open.
namespace :hob do
  namespace :people do
    desc "Read every text backend's stream since the last run into events and loops (what PeopleSyncJob does)"
    task sync: :environment do
      Clearance.with("intimate") do
        Current.set(surface: People::Sync::SURFACE) { People::Sync.run!.each { |report| puts report } }
      end
    end

    desc "Read back over a text backend's messages from a date into events and loops: " \
         "bin/rails \"hob:people:backfill[jenner-messages,2026-09-01]\". Safe to repeat; run hob:people:sync first"
    task :backfill, [ :backend, :since ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:people:backfill[backend,YYYY-MM-DD]\"" if args[:backend].blank?

      Clearance.with("intimate") do
        Current.set(surface: People::Sync::SURFACE) do
          backend = TextBackend.find_by!(name: args[:backend])
          since = args[:since].present? ? Date.iso8601(args[:since]).in_time_zone(Texts.zone) : 30.days.ago
          puts People::Sync.backfill!(backend, since: since)
        end
      end
    end

    desc "Start the Rolodex from a text backend's chats: a person per participant, a group per group chat. " \
         "bin/rails \"hob:people:seed[jenner-messages]\""
    task :seed, [ :backend ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:people:seed[backend]\"" if args[:backend].blank?

      Clearance.with("intimate") do
        result = People::Sync.seed!(TextBackend.find_by!(name: args[:backend]))
        puts "#{result[:chats]} chats read; #{result[:groups]} group chats; #{result[:people]} people known"
      end
    end

    desc "List open loops, the longest-waiting first: bin/rails hob:people:loops [OLDER_THAN=7]"
    task loops: :environment do
      Clearance.with("intimate") do
        filters = { "limit" => 200 }
        filters["older_than"] = ENV["OLDER_THAN"] if ENV["OLDER_THAN"].present?
        rows = People.loops(filters)["loops"]
        puts "no open loops" if rows.empty?
        rows.each do |row|
          puts "#{row['id']}  #{row['age_days'].to_s.rjust(4)}d  #{row['kind'].ljust(18)} #{(row.dig('person', 'display_name') || row.dig('group', 'name')).to_s.ljust(24)} " \
               "#{row['realm'].ljust(9)} #{row['summary']}"
        end
      end
    end

    desc "Move a person to another realm, with their handles: bin/rails \"hob:people:realm[<person id or handle>,household]\". " \
         "Lowering it lets that realm see they exist; their events, loops, and notes keep their own realms"
    task :realm, [ :person, :realm ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:people:realm[person,realm]\"" if args[:person].blank? || args[:realm].blank?

      Clearance.with("intimate") do
        person = People.person!(args[:person])
        Realm.rank_of(args[:realm])
        Person.transaction do
          person.update!(realm: args[:realm])
          person.handles.update_all(realm: args[:realm])
          person.memberships.includes(:group).each { |m| m.update!(realm: People.higher(args[:realm], m.group.realm)) }
        end
        puts "#{person.display_name} (#{person.id}) is #{person.realm}"
      rescue People::Error, ArgumentError => e
        abort e.message
      end
    end
  end
end

# Situation (SITUATION.md): a household person's expiring present moment.
namespace :hob do
  desc "Show a person's current facets and topics: bin/rails \"hob:situation[jenner]\""
  task :situation, [ :person ] => :environment do |_task, args|
    abort "usage: bin/rails \"hob:situation[person]\"" if args[:person].blank?

    Clearance.with("intimate") do
      person = Principal.find_by!(name: args[:person], kind: "human")
      Current.set(principal: person, clearance: "intimate", surface: "terminal") do
        puts JSON.pretty_generate(Situation.get({ "person" => person.name }))
      end
    end
  end

  namespace :situation do
    desc "Set a facet: bin/rails \"hob:situation:set[jenner,availability]\" VALUE='{" \
         "\"state\":\"do_not_disturb\"}' REALM=personal BASIS=stated TTL=7200 OBSERVED_AT=..."
    task :set, [ :person, :kind ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:situation:set[person,kind]\" VALUE='{" \
            "\"state\":\"busy\"}' [REALM=] [BASIS=] [TTL=]" if args[:person].blank? || args[:kind].blank? || ENV["VALUE"].blank?

      Clearance.with("intimate") do
        person = Principal.find_by!(name: args[:person], kind: "human")
        writer = Principal.find_by!(name: ENV["BY"].presence || person.name, kind: "human")
        Current.set(principal: writer, clearance: "intimate", surface: "terminal") do
          observation = { "kind" => args[:kind], "value" => JSON.parse(ENV.fetch("VALUE")) }
          observation["realm"] = ENV["REALM"] if ENV["REALM"].present?
          observation["basis"] = ENV["BASIS"] if ENV["BASIS"].present?
          observation["ttl"] = ENV["TTL"] if ENV["TTL"].present?
          observation["observed_at"] = ENV["OBSERVED_AT"] if ENV["OBSERVED_AT"].present?
          row = Situation.observe(person: person, observations: [ observation ],
                                  by: Situation::Writer.new(principal: writer, surface: "terminal", clearance: "intimate")).sole
          puts "#{person.name}: #{row.kind} at #{row.realm} until #{row.expires_at.utc.iso8601} (#{row.id})"
        end
      end
    rescue JSON::ParserError => e
      abort "VALUE is not JSON: #{e.message}"
    rescue Situation::Error => e
      abort e.message
    end

    desc "Set or refresh a topic: bin/rails \"hob:situation:topic[jenner,adu-permit]\" TEXT='county says two more weeks'"
    task :topic, [ :person, :slot ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:situation:topic[person,slot]\" TEXT=... [DETAIL=] [REALM=] [TTL=]" \
        if args[:person].blank? || args[:slot].blank? || ENV["TEXT"].blank?

      Clearance.with("intimate") do
        person = Principal.find_by!(name: args[:person], kind: "human")
        writer = Principal.find_by!(name: ENV["BY"].presence || person.name, kind: "human")
        Current.set(principal: writer, clearance: "intimate", surface: "terminal") do
          observation = { "kind" => "topic", "slot" => args[:slot],
                          "value" => { "text" => ENV["TEXT"], "detail" => ENV["DETAIL"].presence }.compact }
          observation["realm"] = ENV["REALM"] if ENV["REALM"].present?
          observation["ttl"] = ENV["TTL"] if ENV["TTL"].present?
          row = Situation.observe(person: person, observations: [ observation ],
                                  by: Situation::Writer.new(principal: writer, surface: "terminal", clearance: "intimate")).sole
          puts "#{person.name}: topic #{row.slot} at #{row.realm} until #{row.expires_at.utc.iso8601} (#{row.id})"
        end
      end
    rescue Situation::Error => e
      abort e.message
    end

    desc "End a facet or topic: bin/rails \"hob:situation:end[jenner,topic,adu-permit]\""
    task :end, [ :person, :kind, :slot ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:situation:end[person,kind,slot?]\"" if args[:person].blank? || args[:kind].blank?

      Clearance.with("intimate") do
        person = Principal.find_by!(name: args[:person], kind: "human")
        writer = Principal.find_by!(name: ENV["BY"].presence || person.name, kind: "human")
        Current.set(principal: writer, clearance: "intimate", surface: "terminal") do
          rows = Situation.end_observation(
            person: person, kind: args[:kind], slot: args[:slot],
            by: Situation::Writer.new(principal: writer, surface: "terminal", clearance: "intimate")
          )
          puts rows.any? ? "#{person.name}: ended #{rows.size} #{args[:kind]} observation(s)" : "#{person.name}: nothing current to end"
        end
      end
    rescue Situation::Error => e
      abort e.message
    end
  end
end
