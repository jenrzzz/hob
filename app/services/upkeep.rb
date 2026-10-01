require "zlib"

# Upkeep (SCHEDULES.md, "Upkeep"): keep every app the household runs on
# Coolify current. Discovery reads Coolify's applications, keeps those
# built from a GitHub repo the household owns (HOB_UPKEEP_OWNERS), and
# gives each repo two schedules for the forge:
#
#   upkeep-<repo>         weekly, scope minor: patch and minor upgrades,
#                         merged by the forge when they are provably safe
#   upkeep-<repo>-major   monthly, scope major: one framework, runtime, or
#                         major upgrade, always a PR for a person
#
# Times are spread across the week and month by the repo's name, in the
# small hours of HOB_TIME_ZONE. Discovery owns the payload; a person owns
# the timing and whether it is on: a retimed or disabled schedule stays
# that way. A repo that leaves Coolify has its schedules disabled, not
# deleted.
module Upkeep
  KIND = "forge.upkeep".freeze # Forge::Upkeep::KIND, which the app does not load
  PREFIX = "upkeep-".freeze

  Report = Struct.new(:repos, :created, :updated, :disabled, keyword_init: true)

  module_function

  def owners
    ENV.fetch("HOB_UPKEEP_OWNERS", "jenrzzz").split(",").map(&:strip).reject(&:empty?)
  end

  def forge
    Principal.find_by(name: ENV.fetch("HOB_FORGE_PRINCIPAL", "forge"), kind: "worker")
  end

  # "jenrzzz/hob" from any way Coolify spells a GitHub source; nil otherwise.
  def repo_of(source)
    match = source.to_s.strip.match(%r{\A(?:(?:https?://|git@)github\.com[/:])?([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?\z})
    match && "#{match[1]}/#{match[2]}"
  end

  # { "owner/name" => branch } for the apps worth keeping up, one per repo.
  def repos(coolify)
    coolify.applications.each_with_object({}) do |app, found|
      repo = repo_of(app["git_repository"])
      next if repo.nil? || !owners.include?(repo.split("/").first)

      found[repo] ||= app["git_branch"].presence
    end
  end

  # Reconcile the upkeep schedules with what Coolify runs. -> Report
  def discover!(coolify: Provision::Coolify.from_env, dry_run: false)
    worker = forge
    raise ArgumentError, "no forge worker is set up (bin/rails \"hob:forge:setup[forge]\")" if worker.nil?

    found = repos(coolify)
    report = Report.new(repos: found.keys.sort, created: [], updated: [], disabled: [])
    Schedule.transaction do
      found.each do |repo, branch|
        %w[minor major].each do |scope|
          schedule = Schedule.find_or_initialize_by(created_by: nil, name: schedule_name(repo, scope))
          fresh = schedule.new_record?
          schedule.assign_attributes(
            assignee: worker, realm: "household", priority: -1,
            title: "upkeep: #{repo}#{' (major)' if scope == 'major'}",
            description: "keep #{repo} current (#{scope}); found on Coolify",
            payload: { "kind" => KIND, "repo" => repo, "branch" => branch, "scope" => scope }.compact
          )
          if fresh
            schedule.cron = cron_for(repo, scope)
            schedule.time_zone = ENV.fetch("HOB_TIME_ZONE", "Etc/UTC")
          end
          next unless fresh || schedule.changed?

          (fresh ? report.created : report.updated) << schedule.name
          schedule.save! unless dry_run
        end
      end

      Schedule.where(created_by: nil, enabled: true).where("name LIKE ?", "#{PREFIX}%").find_each do |schedule|
        next if schedule.payload["kind"] != KIND || found.key?(schedule.payload["repo"])

        report.disabled << schedule.name
        schedule.update!(enabled: false, description: "#{schedule.payload['repo']} is no longer on Coolify") unless dry_run
      end
    end
    report
  end

  def schedule_name(repo, scope)
    base = "#{PREFIX}#{repo.split('/').last.downcase.gsub(/[^a-z0-9._-]/, '-')}"
    scope == "major" ? "#{base}-major" : base
  end

  # Spread by the repo's name: minor weekly between 2 and 5am on its own
  # weekday, major on its own day of the month at 3am.
  def cron_for(repo, scope)
    seed = Zlib.crc32(repo)
    minute = (seed % 4) * 15
    if scope == "major"
      "#{minute} 3 #{(seed / 4 % 28) + 1} * *"
    else
      "#{minute} #{2 + (seed / 4 % 4)} * * #{seed / 16 % 7}"
    end
  end
end
