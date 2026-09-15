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

    desc "List requests waiting for a person"
    task pending: :environment do
      Clearance.with("intimate") do
        rows = SentinelRequest.pending.recent.includes(:capability, :principal)
        puts "nothing pending" if rows.empty?
        rows.each do |r|
          puts "#{r.id}  #{r.created_at.utc.iso8601}  #{r.principal.name} → #{r.capability.name}  (#{r.rationale})"
          puts "  arguments: #{r.arguments.to_json}"
          puts "  reason: #{r.reason}" if r.reason.present?
        end
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
