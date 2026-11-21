# Commissions (CODE.md): work an agent hands to Claude Code. A commission is
# a mission for the forge (`forge.commission`, lib/forge/commission.rb): a
# brief in the agent's words, done in a fresh sandbox, in a repo that is the
# agent's own (a `code_repos` row), and pushed there. It is slow and it is
# asynchronous: the agent starts one and reads how it went later.
#
#   Commissions.start(title: "A guestbook", brief: "A small page where ...")
#   Commissions.status            # the caller's recent commissions
#   Commissions.status(id)        # one, with what Claude Code said
#
# Which repos exist for a call is RLS's answer narrowed to the caller's own
# (`repos`); a commission belongs to whoever started it.
module Commissions
  class Error < StandardError; end
  class NotFound < Error; end     # no such repo or commission (or not visible, or not yours)
  class Invalid < Error; end      # the caller's mistake
  class Unavailable < Error; end  # no forge to hand it to, or too many already under way

  KIND = "forge.commission".freeze # Forge::Commission::KIND, which the app does not load
  BRANCH = %r{\A[A-Za-z0-9][A-Za-z0-9._/-]{0,79}\z}
  TITLE_MAX = 120
  BRIEF_MIN = 40
  BRIEF_MAX = 20_000
  MAX_OPEN = 2
  RECENT = 10
  STATES = { "queued" => "waiting", "leased" => "working", "completed" => "done", "failed" => "failed", "cancelled" => "cancelled" }.freeze

  module_function

  # Enabled repos visible at the current clearance: a person reaches every
  # one, an agent only its own.
  def repos(caller = Current.principal)
    rows = CodeRepo.enabled.order(:name)
    return rows if caller&.trusted?

    caller ? rows.where(agent_id: caller.id) : rows.none
  end

  def forge
    Upkeep.forge
  end

  # Queue a commission. -> its summary, as `status` gives it
  def start(brief:, title:, branch: nil, repo: nil, request: nil)
    title = title.to_s.squish
    raise Invalid, "title is a few words naming the work, at most #{TITLE_MAX} characters" unless title.length.between?(3, TITLE_MAX)
    unless brief.is_a?(String) && brief.strip.length.between?(BRIEF_MIN, BRIEF_MAX)
      raise Invalid, "brief is the whole request in your own words, #{BRIEF_MIN} to #{BRIEF_MAX} characters: what to make, how it should behave, " \
                     "what is already there, how you will run it. Claude Code knows nothing but the brief and the repo"
    end
    if branch.present? && !(branch.is_a?(String) && branch.match?(BRANCH) && !branch.include?("..") && !branch.end_with?("/", ".lock"))
      raise Invalid, "branch is a git branch name, like main or guestbook"
    end

    row = repo_named(repo)
    worker = forge or raise Unavailable, "there is no forge to hand work to"
    open = mine.open.count
    raise Unavailable, "you have #{open} commissions under way already; wait for one to finish (code.status)" if open >= MAX_OPEN

    mission = Mission.create!(
      assignee: worker, created_by: Current.principal, title: "Commission: #{title}", brief: brief.strip.truncate(500),
      realm: request&.realm || Clearance.current,
      payload: { "kind" => KIND, "repo" => row.repo, "branch" => branch.presence, "title" => title, "brief" => brief.strip,
                 "for" => Current.principal&.name, "code_repo" => row.name }.compact
    )
    summary(mission)
  end

  # One commission in full, or the caller's recent ones in brief.
  def status(id = nil)
    return mine.order(created_at: :desc).limit(RECENT).map { |mission| summary(mission) } if id.blank?

    mission = mine.find_by(id: id.to_s) or raise NotFound, "no commission #{id.inspect}"
    summary(mission, full: true)
  end

  # An agent's last few commissions, newest first, for telling it (a
  # persona's beat). Read at the current clearance.
  def recent(agent, limit: 3)
    of(agent).order(created_at: :desc).limit(limit).map { |mission| summary(mission) }
  end

  # --- private-ish ---

  def of(principal)
    Mission.where(created_by: principal).where("payload->>'kind' = ?", KIND)
  end

  # A person sees every commission; an agent its own.
  def mine
    caller = Current.principal
    caller&.trusted? ? Mission.where("payload->>'kind' = ?", KIND) : of(caller)
  end

  def repo_named(name)
    rows = repos.to_a
    if name.present?
      rows.find { |row| row.name == name.to_s } or raise NotFound, "no repo named #{name.inspect}#{rows.any? ? " (yours: #{rows.map(&:name).join(', ')})" : ''}"
    else
      raise NotFound, "no repo is set up for you to commission work in" if rows.empty?
      raise Invalid, "name the repo: one of #{rows.map(&:name).join(', ')}" if rows.size > 1

      rows.first
    end
  end

  def summary(mission, full: false)
    payload = mission.payload.to_h
    result = mission.result.to_h
    said = result["summary"].to_s
    {
      "id" => mission.id, "title" => payload["title"], "state" => STATES.fetch(mission.status, mission.status),
      "repo" => payload["code_repo"], "branch" => result["branch"] || payload["branch"],
      "asked_at" => mission.created_at.utc.iso8601,
      "finished_at" => (mission.updated_at.utc.iso8601 if %w[completed failed cancelled].include?(mission.status)),
      "outcome" => result["status"], "commits" => (full ? result["commits"] : result["commit_count"]),
      "files" => result["files"], "url" => result["url"],
      "said" => (full ? said.presence : said.lines.first.to_s.strip.truncate(240).presence),
      "error" => mission.error.presence&.truncate(full ? 2_000 : 240),
      "brief" => (payload["brief"] if full)
    }.compact
  end
end
