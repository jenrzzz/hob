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
       "bin/rails \"hob:agent[muse,clearance=household,surface=muse]\" (re-running rotates the key)"
  task :agent, [ :name, :clearance, :surface ] => :environment do |_task, args|
    abort "usage: bin/rails \"hob:agent[name,clearance=household,surface=name]\"" if args[:name].blank?

    clearance = args[:clearance].presence || "household"
    Realm.rank_of(clearance)
    agent = Principal.find_or_create_by!(name: args[:name]) { |p| p.kind = "agent"; p.max_clearance = clearance }
    abort "#{agent.name} is a #{agent.kind}, not an agent" unless agent.agent?

    surface = args[:surface].presence || agent.name
    token = ApiKey.issue!(principal: agent, surface: surface, default_clearance: clearance)
    rotated = agent.api_keys.where(surface: surface).where.not(token_digest: ApiKey.digest(token)).destroy_all.size
    rules = agent.sentinel_policies.count + SentinelPolicy.where(principal_id: nil).count
    puts "#{agent.name}: agent key (shown once): #{token}"
    puts "clearance #{clearance}, surface #{surface}, rotated #{rotated} old key(s); " \
         "#{rules.zero? ? 'no policies yet — every request will be denied until you add some' : "#{rules} policy rule(s) apply"}"
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
      puts "rotated #{rotated} old key(s). On the coder box: HOB_URL=https://... HOB_KEY=<key> bin/forge"
    end
  end
end
