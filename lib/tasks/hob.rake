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

    desc "Decide a pending request as a person. bin/rails \"hob:sentinel:decide[<id>,allow|deny,jenner]\" RATIONALE='...'"
    task :decide, [ :id, :decision, :principal ] => :environment do |_task, args|
      abort "usage: bin/rails \"hob:sentinel:decide[id,allow|deny,principal=jenner]\"" if args[:id].blank? || args[:decision].blank?

      Clearance.with("intimate") do
        decider = Principal.find_by!(name: args[:principal].presence || "jenner")
        row = Sentinel.decide!(SentinelRequest.find(args[:id]), decision: args[:decision], decider: decider, rationale: ENV["RATIONALE"])
        puts "#{row.id}: #{row.status}#{row.error && " (#{row.error})"}"
      end
    end
  end
end

namespace :hob do
  namespace :surface do
    desc "Register the capabilities a surface offers the sentinel (SENTINEL.md) from its manifest at /hob/capabilities, " \
         "and hand it the secret hob signs deliveries with. bin/rails \"hob:surface:register[mise,https://mise.amber.place]\" " \
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
      puts "#{ward.name}: worker key (shown once): #{token}"
      puts "rotated #{rotated} old key(s). Checks: #{WardCheck.order(:slug).pluck(:slug).join(', ')} (exposure every #{check.interval_seconds / 86_400}d)"
      puts "On the runner: HOB_URL=https://... HOB_KEY=<key> COOLIFY_BASE_URL= COOLIFY_API_TOKEN=<read-only> python3 security/ward.py work --every #{check.interval_seconds}"
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

    desc "The ward's clock: raise stale checks, expire acknowledgements, triage what changed. Run hourly (a Coolify scheduled task)."
    task sweep: :environment do
      Clearance.with("intimate") do
        Current.set(surface: Ward::SURFACE) do
          run = Ward::Sweep.call
          puts run ? "sweep: #{run.mechanical_summary}" : "sweep: nothing changed"
        end
      end
    end
  end
end
