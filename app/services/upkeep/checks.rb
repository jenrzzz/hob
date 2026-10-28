require "net/http"

module Upkeep
  # The red-branch watch (SCHEDULES.md, "Upkeep"): every quarter hour
  # (UpkeepChecksJob), read the checks on the head of each kept repo's
  # branch, and when they have all finished and one failed, queue a
  # `forge.upkeep` mission of scope fix for the forge, which opens a PR
  # for a person. One attempt per commit, and one fix at a time per repo:
  # a newer red head waits for the open one to settle. A repo whose
  # weekly upkeep schedule is disabled is left alone here too.
  module Checks
    class Error < StandardError; end

    # Check run conclusions that mean the code is red. cancelled is mostly a
    # newer push superseding a run; action_required is a person's approval.
    FAILED = %w[failure timed_out startup_failure].freeze

    # state: green | red | pending | none (nothing reports on the commit)
    Verdict = Struct.new(:repo, :branch, :sha, :state, :failures, keyword_init: true)
    Report = Struct.new(:checked, :queued, :errors, keyword_init: true)

    module_function

    def configured?
      ENV["HOB_GITHUB_TOKEN"].present?
    end

    # What GitHub says of the head of `branch` (the repo's default when nil).
    def read(github, repo, branch)
      branch ||= github.get("/repos/#{repo}")["default_branch"]
      status = github.get("/repos/#{repo}/commits/#{branch}/status")
      sha = status["sha"]
      runs = Array(github.get("/repos/#{repo}/commits/#{sha}/check-runs?per_page=100")["check_runs"])
      statuses = Array(status["statuses"])

      failures = runs.select { |r| FAILED.include?(r["conclusion"]) }.map do |r|
        { "name" => r["name"], "url" => r["details_url"] || r["html_url"],
          "summary" => [ r.dig("output", "title"), r.dig("output", "summary") ].compact_blank.join("\n").truncate(500).presence }.compact
      end
      failures += statuses.select { |s| %w[failure error].include?(s["state"]) }.map do |s|
        { "name" => s["context"], "url" => s["target_url"], "summary" => s["description"] }.compact_blank
      end
      pending = runs.any? { |r| r["status"] != "completed" } || statuses.any? { |s| s["state"] == "pending" }
      state = if pending then "pending"
      elsif failures.any? then "red"
      elsif runs.any? || statuses.any? then "green"
      else "none"
      end
      Verdict.new(repo: repo, branch: branch, sha: sha, state: state, failures: failures)
    end

    # Read every kept repo, and queue a fix for each one that is red. -> Report
    def watch!(github: Client.from_env, dry_run: false)
      worker = Upkeep.forge
      raise ArgumentError, "no forge worker is set up (bin/rails \"hob:forge:setup[forge]\")" if worker.nil?

      report = Report.new(checked: {}, queued: [], errors: {})
      Upkeep.schedules.where(enabled: true).where("payload->>'scope' = ?", "minor").find_each do |schedule|
        repo = schedule.payload["repo"]
        verdict = begin
          read(github, repo, schedule.payload["branch"])
        rescue Error => e
          report.errors[repo] = e.message
          next
        end
        report.checked[repo] = verdict.state
        next unless verdict.state == "red" && !fixing?(repo, verdict.sha)

        report.queued << repo
        queue!(schedule, verdict, worker) unless dry_run
      end
      report
    end

    def fixes
      Mission.where("payload->>'kind' = ? AND payload->>'scope' = ?", KIND, "fix")
    end

    # Already tried at this commit, or a fix for the repo is under way.
    def fixing?(repo, sha)
      mine = fixes.where("payload->>'repo' = ?", repo)
      mine.open.exists? || mine.exists?([ "payload->>'sha' = ?", sha ])
    end

    # Under the repo's weekly schedule, so it reports to the household as
    # that schedule's missions do (Mission#report!).
    def queue!(schedule, verdict, worker)
      names = verdict.failures.map { |f| f["name"] }
      Mission.create!(
        assignee: worker, schedule: schedule, realm: "household", priority: 0,
        title: "upkeep: fix #{verdict.repo}",
        brief: "#{verdict.branch} failed #{names.to_sentence} at #{verdict.sha[0, 7]}".truncate(500),
        payload: { "kind" => KIND, "repo" => verdict.repo, "branch" => verdict.branch, "scope" => "fix",
                   "sha" => verdict.sha, "failures" => verdict.failures.first(20) }
      )
    end

    # GitHub's REST API with HOB_GITHUB_TOKEN: read access to the kept
    # repos' checks, commit statuses, and metadata is all it needs.
    # `transport` responds to call(path) → parsed JSON, for tests.
    class Client
      BASE = "https://api.github.com".freeze

      def self.from_env
        new(token: ENV["HOB_GITHUB_TOKEN"])
      end

      def initialize(token: nil, transport: nil)
        raise Error, "HOB_GITHUB_TOKEN is not set" if transport.nil? && token.blank?

        @token = token
        @transport = transport
      end

      def get(path)
        return @transport.call(path) if @transport

        uri = URI("#{BASE}#{path}")
        request = ::Net::HTTP::Get.new(uri)
        request["Authorization"] = "Bearer #{@token}"
        request["Accept"] = "application/vnd.github+json"
        request["X-GitHub-Api-Version"] = "2022-11-28"
        response = ::Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |http| http.request(request) }
        data = JSON.parse(response.body.presence || "{}") rescue {}
        return data if response.code.start_with?("2")

        raise Error, "GitHub GET #{path}: HTTP #{response.code} #{data['message'] if data.is_a?(Hash)}".strip
      rescue SocketError, SystemCallError, ::Net::OpenTimeout, ::Net::ReadTimeout => e
        raise Error, "GitHub unreachable: #{e.message}"
      end
    end
  end
end
