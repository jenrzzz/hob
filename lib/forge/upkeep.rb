module Forge
  # Upkeep (SCHEDULES.md, "Upkeep"): keep one of the household's apps
  # current. A `forge.upkeep` mission names a GitHub repo, a branch, and a
  # scope:
  #
  #   minor  merge the green Dependabot PRs that are not majors, then have
  #          Claude Code take every dependency to its newest patch or minor
  #          release; the forge runs the repo's tests itself, and merges the
  #          PR when only lockfiles changed, no version crossed a major, the
  #          tests passed, and no GitHub check failed. Anything else is left
  #          as a PR for a person.
  #   major  one framework, runtime, or major-version upgrade, with the code
  #          changes it needs. Always a PR for a person.
  #
  # Whether a PR may merge is decided here, from the diff, the lockfiles, and
  # the forge's own test run, never from what the implementer says. Each
  # scope has one branch per repo (upkeep/minor, upkeep/major), rebuilt from
  # the base and force-pushed every run, so an unmerged PR is refreshed in
  # place rather than joined by another.
  class Upkeep
    KIND = "forge.upkeep".freeze
    SCOPES = %w[minor major].freeze
    REPO = %r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z}

    # The headless implementer may update, install, and test with the tools
    # of the stacks it finds, and commit. FORGE_UPKEEP_CLAUDE_ARGS replaces it.
    CLAUDE_ARGS = [
      "--permission-mode", "acceptEdits",
      "--allowedTools", "Read", "Edit", "Write", "Glob", "Grep",
      "Bash(bundle update:*)", "Bash(bundle install:*)", "Bash(bundle outdated:*)", "Bash(bundle lock:*)", "Bash(bundle exec:*)",
      "Bash(bin/rails test)", "Bash(bin/rails test:*)", "Bash(bin/rails app:update:*)", "Bash(bin/rspec:*)", "Bash(bin/rubocop:*)",
      "Bash(env RAILS_ENV=test bin/rails db:test:prepare)",
      "Bash(npm install:*)", "Bash(npm update:*)", "Bash(npm outdated:*)", "Bash(npm ci:*)", "Bash(npm test:*)", "Bash(npm run:*)",
      "Bash(npx:*)", "Bash(uv lock:*)", "Bash(uv sync:*)", "Bash(uv run:*)", "Bash(uv pip list:*)", "Bash(uv tree:*)",
      "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git add:*)", "Bash(git commit:*)", "Bash(git show:*)",
      "Bash(ls:*)", "Bash(cat:*)", "Bash(grep:*)", "Bash(rg:*)", "Bash(sed -n:*)", "Bash(head:*)", "Bash(tail:*)", "Bash(wc:*)",
      "Bash(ruby -v)", "Bash(ruby --version)", "Bash(bundle -v)", "Bash(bundle --version)", "Bash(bundle list:*)",
      "Bash(gem list:*)", "Bash(node -v)", "Bash(node --version)", "Bash(npm -v)", "Bash(npm ls:*)", "Bash(uv --version)",
      "Bash(python3 --version)"
    ].freeze
    CO_AUTHOR = "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>".freeze

    def self.check!(payload)
      payload = (payload || {}).to_h
      raise Error, "not a #{KIND} mission (kind #{payload['kind'].inspect})" unless payload["kind"] == KIND

      repo = payload["repo"].to_s
      raise Error, "#{repo.inspect} is not an owner/name GitHub repo" unless repo.match?(REPO)
      raise Error, "scope #{payload['scope'].inspect} is not one of #{SCOPES.join(', ')}" unless SCOPES.include?(payload.fetch("scope", "minor"))

      repo
    end

    # "8.1.3" -> [8, 1, 3]; platform and prerelease suffixes are dropped.
    def self.segments(version)
      version.to_s.sub(/\Av/, "").split(/[-+]/).first.to_s.split(".").map { |s| s[/\A\d+/].to_i }
    end

    # A major: the first segment moved, or, below 1.0, the second (0.x
    # minors break, by semver's own rule). A downgrade counts too. zero:
    # false drops the 0.x rule, for what the app does not depend on itself:
    # Ruby's default gems and the like sit below 1.0 for years and move a
    # minor most months.
    def self.major?(from, to, zero: true)
      a = segments(from)
      b = segments(to)
      return true if a.empty? || b.empty?
      return a[0] != b[0] if a[0].positive? || b[0].positive? || !zero

      a[1].to_i != b[1].to_i
    end

    attr_reader :payload, :repo, :scope, :workdir, :log

    def initialize(payload:, workdir:, runner: nil, claude_args: nil, log: $stderr, checks_wait: 1800, poll: 30,
                   clock: nil, sleeper: nil)
      @payload = (payload || {}).to_h
      @repo = Upkeep.check!(@payload)
      @scope = @payload.fetch("scope", "minor")
      @base = @payload["branch"].to_s.empty? ? nil : @payload["branch"].to_s
      @workdir = File.expand_path(workdir)
      @runner = runner || Forge.method(:run)
      @claude_args = claude_args || (ENV["FORGE_UPKEEP_CLAUDE_ARGS"] ? Shellwords.split(ENV["FORGE_UPKEEP_CLAUDE_ARGS"]) : CLAUDE_ARGS)
      @log = log
      @checks_wait = checks_wait
      @poll = poll
      @clock = clock || -> { Time.now }
      @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    end

    def branch
      "upkeep/#{scope}"
    end

    def dir
      @dir ||= File.join(workdir, "upkeep-#{repo.tr('/', '-')}-#{scope}")
    end

    # -> { "repo", "scope", "status", "pull_request"?, "merged", "review"?, "tests", "changes", "dependabot", "summary", "cost", "notify" }
    # status: current (nothing to do) | merged | review (a PR waits for a person)
    def call
      FileUtils.mkdir_p(workdir) # gh runs in it before the clone does; a fresh workspace has none
      dependabot = scope == "minor" ? merge_dependabot : []
      clone
      outcome = implement
      refused = File.join(dir, ".forge", "REFUSED.md")
      raise Refused, "the implementer refused: #{File.read(refused).strip}" if File.exist?(refused)

      majors_available = read_forge_file("MAJORS.md")
      commit_leftovers(outcome)
      changed = changed_files
      if changed.empty?
        stale = scope == "minor" ? still_outdated(outcome) : []
        if stale.any?
          cleanup
          raise Error, "nothing changed, yet #{stale.size} dependenc#{stale.size == 1 ? 'y has' : 'ies have'} a newer release " \
                       "within range: #{stale.first(8).join(', ')}#{' ...' if stale.size > 8}#{said(outcome)}"
        end
        say "nothing to upgrade"
        cleanup
        return result("current", outcome, dependabot: dependabot, majors_available: majors_available,
                      summary: "#{repo}: current#{" (merged #{dependabot.size} Dependabot PR(s))" if dependabot.any?}")
      end

      changes = lockfile_changes(changed)
      tests = run_tests
      push
      url = open_pull_request(outcome, changes, tests, majors_available)
      blockers = review_reasons(changed, changes, tests)
      blockers.concat(checks_blockers(url)) if blockers.empty?
      merged = blockers.empty? && merge(url, blockers)
      cleanup
      status = merged ? "merged" : "review"
      result(status, outcome, url: url, merged: merged, review: blockers, tests: tests, changes: changes,
                              dependabot: dependabot, majors_available: majors_available,
                              summary: summary(status, url, changes, blockers, dependabot))
    end

    # --- Dependabot ----------------------------------------------------------

    # Merge the open Dependabot PRs that bump one dependency within its
    # major and whose checks all passed. A grouped PR, a major, a pending or
    # failing check, or a merge GitHub refuses is left for a person.
    def merge_dependabot
      status, out, = gh("pr", "list", "--repo", repo, "--author", "app/dependabot", "--state", "open",
                        "--json", "number,title,url", "--limit", "50")
      return [] unless status.zero?

      prs = JSON.parse(out) rescue []
      prs.filter_map do |pr|
        bump = pr["title"].to_s.match(/\ABump (\S+) from (\S+) to (\S+)/)
        next if bump.nil? || Upkeep.major?(bump[2], bump[3])
        next unless checks_state(pr["url"]) == "pass"

        status, _out, err = gh("pr", "merge", pr["url"], "--squash", "--delete-branch")
        if status.zero?
          say "merged Dependabot's #{pr['title']}"
          { "name" => bump[1], "from" => bump[2], "to" => bump[3], "pull_request" => pr["url"] }
        else
          say "could not merge #{pr['url']}: #{err.strip}"
          nil
        end
      end
    end

    # --- the build -----------------------------------------------------------

    def clone
      FileUtils.mkdir_p(workdir)
      FileUtils.rm_rf(dir)
      say "cloning #{repo}"
      args = [ "repo", "clone", repo, dir, "--", "--quiet" ]
      args += [ "--branch", @base ] if @base
      status, out, err = gh(*args, chdir: workdir)
      raise Error, "could not clone #{repo}: #{(err.strip.empty? ? out : err).strip}" unless status.zero?

      @base ||= git!(%w[rev-parse --abbrev-ref HEAD]).strip
      git! %w[checkout --quiet -B], branch
      FileUtils.mkdir_p(File.join(dir, ".forge"))
      File.write(File.join(dir, ".forge", "BRIEF.md"), brief)
      File.open(File.join(dir, ".git", "info", "exclude"), "a") { |f| f.puts ".forge/" }
    end

    def base
      @base || "main"
    end

    def implement
      say "running Claude Code (#{scope})"
      status, out, err = run([ "claude", "-p", "--output-format", "json", *@claude_args ], chdir: dir, stdin: brief)
      outcome = parse_outcome(out)
      raise Error, "claude exited #{status}: #{excerpt(outcome['result'] || err || out)}" unless status.zero?
      raise Error, "claude reported an error: #{excerpt(outcome['result'])}" if outcome["is_error"]

      say "implementer finished (#{outcome['num_turns']} turns, $#{outcome['total_cost_usd']})"
      outcome
    end

    def commit_leftovers(outcome)
      dirty = git!(%w[status --porcelain --untracked-files=all]).lines.map(&:strip).reject { |l| l.include?(".forge/") }
      return if dirty.empty?

      say "committing #{dirty.size} change(s) the implementer left"
      git! %w[add -A -- .]
      git! %w[commit --quiet -m], "Upkeep: #{scope} upgrades\n\n#{outcome['result'].to_s.lines.first.to_s.strip}\n\n#{CO_AUTHOR}\n"
    end

    def changed_files
      git!(%w[diff --name-only], "#{base_ref}...HEAD").lines.map(&:strip).reject(&:empty?)
    end

    def base_ref
      "origin/#{base}"
    end

    # A minor run that changed nothing is current only if the stack's own
    # tools agree: an implementer that could not work (a Ruby the sandbox
    # lacks, a bundle that would not resolve) and stopped without refusing
    # must not pass for a repo with nothing to do. A check that cannot run
    # fails the mission too. -> ["rails 8.1.3.1 → 8.1.4"]
    def still_outdated(outcome)
      found = []
      if file?("Gemfile.lock")
        check!(outcome, %w[bundle install --quiet])
        status, out, err = run(%w[bundle outdated --strict --filter-minor --filter-patch --parseable], chdir: dir)
        lines = out.scan(/^(\S+) \(newest ([^,]+), installed ([^,)]+)/)
        raise Error, "could not check the bundle: #{excerpt(err + out, 1000)}#{said(outcome)}" if !status.zero? && lines.empty?

        found += lines.map { |name, newest, installed| "#{name} #{installed} → #{newest}" }
      end
      if file?("package-lock.json")
        check!(outcome, %w[npm ci --ignore-scripts])
        _status, out, err = run(%w[npm outdated --json], chdir: dir)
        data = out.strip.empty? ? {} : (JSON.parse(out) rescue nil)
        raise Error, "could not check the npm packages: #{excerpt(err + out, 1000)}#{said(outcome)}" unless data.is_a?(Hash)

        data.each do |name, info|
          (info.is_a?(Array) ? info : [ info ]).each do |i|
            next if i["current"].nil? || i["wanted"].nil? || i["current"] == i["wanted"]

            found << "#{name} #{i['current']} → #{i['wanted']}"
          end
        end
      end
      if file?("uv.lock")
        status, out, err = run(%w[uv lock --upgrade --dry-run], chdir: dir)
        raise Error, "could not check uv.lock: #{excerpt(err + out, 1000)}#{said(outcome)}" unless status.zero?

        found += (err + out).scan(/^\s*Update (\S+) v(\S+) -> v(\S+)/)
                            .reject { |_, from, to| Upkeep.major?(from, to) }
                            .map { |name, from, to| "#{name} #{from} → #{to}" }
      end
      found.uniq
    end

    def check!(outcome, argv)
      status, out, err = run(argv, chdir: dir)
      raise Error, "#{argv.first(2).join(' ')} failed: #{excerpt((out + err).lines.last(20).join, 1000)}#{said(outcome)}" unless status.zero?
    end

    # What the implementer said, for a failure's message.
    def said(outcome)
      text = outcome["result"].to_s.strip
      text.empty? ? "" : "\nthe implementer said: #{excerpt(text, 1500)}"
    end

    # The repo's own tests, chosen from what is there, not by the implementer.
    # -> { "status" => passed|failed|none, "commands" => [{ command, ok, output? }] }
    def run_tests
      steps = test_plan
      return { "status" => "none", "commands" => [] } if steps.empty?

      commands = []
      steps.each do |argv, label|
        say "running #{label}"
        status, out, err = run(argv, chdir: dir)
        entry = { "command" => label, "ok" => status.zero? }
        entry["output"] = excerpt((out + err).lines.last(30).join, 1500) unless status.zero?
        commands << entry
        break unless status.zero?
      end
      { "status" => commands.all? { |c| c["ok"] } ? "passed" : "failed", "commands" => commands }
    end

    # [[argv, label]] in order: setup steps, then the tests, per stack.
    def test_plan
      plan = []
      if file?("Gemfile")
        plan << [ %w[bundle install --quiet], "bundle install" ]
        rails = file?("bin/rails")
        plan << [ %w[env RAILS_ENV=test bin/rails db:test:prepare], "db:test:prepare" ] if rails && file?("config/database.yml")
        if File.directory?(File.join(dir, "spec")) && read("Gemfile.lock").include?(" rspec-core ")
          plan << [ %w[bundle exec rspec], "rspec" ]
        elsif rails && File.directory?(File.join(dir, "test"))
          plan << [ %w[bin/rails test], "bin/rails test" ]
        end
      end
      if file?("package.json")
        test_script = (JSON.parse(read("package.json"))["scripts"] || {})["test"].to_s rescue ""
        unless test_script.empty? || test_script.include?("no test specified")
          plan << [ file?("package-lock.json") ? %w[npm ci] : %w[npm install], "npm install" ]
          plan << [ %w[env CI=1 npm test], "npm test" ]
        end
      end
      if file?("pyproject.toml") && %w[tests test].any? { |d| File.directory?(File.join(dir, d)) } &&
         (read("pyproject.toml") + read("uv.lock")).include?("pytest")
        plan << [ %w[uv sync], "uv sync" ] if file?("uv.lock")
        plan << [ %w[uv run pytest -q], "pytest" ]
      end
      plan.any? { |_, label| label.match?(/rspec|test|pytest/) } ? plan : []
    end

    # --- what changed --------------------------------------------------------

    LOCKFILES = {
      "Gemfile.lock" => :gemfile_lock, "package-lock.json" => :package_lock,
      "uv.lock" => :toml_lock, "poetry.lock" => :toml_lock
    }.freeze

    # Every version that moved in a lockfile this branch changed. The 0.x
    # rule holds for the app's direct dependencies only, and for all of them
    # where the lockfile does not say which those are.
    # -> [{ "file", "name", "from", "to", "major" }]
    def lockfile_changes(changed)
      changed.select { |f| LOCKFILES.key?(File.basename(f)) }.flat_map do |file|
        parser = LOCKFILES[File.basename(file)]
        old_text = git(%w[show], "#{base_ref}:#{file}")[1].to_s
        new_text = read(file)
        before = send(parser, old_text)
        after = send(parser, new_text)
        direct = direct_dependencies(file, old_text, new_text)
        (before.keys | after.keys).filter_map do |name|
          from = before[name]
          to = after[name]
          next if from == to || from.nil? || to.nil? # added or removed: a transitive reshuffle, not an upgrade

          major = Upkeep.major?(from, to, zero: direct.nil? || direct.include?(name))
          { "file" => file, "name" => name, "from" => from, "to" => to, "major" => major }
        end
      end
    end

    # Why this PR needs a person; empty when it may merge.
    def review_reasons(changed, changes, tests)
      reasons = []
      reasons << "scope is major: always reviewed" if scope == "major"
      others = changed.reject { |f| LOCKFILES.key?(File.basename(f)) }
      reasons << "changes beyond lockfiles: #{others.first(8).join(', ')}#{' ...' if others.size > 8}" if others.any?
      majors = changes.select { |c| c["major"] }
      reasons << "major versions: #{majors.first(8).map { |c| "#{c['name']} #{c['from']} → #{c['to']}" }.join(', ')}" if majors.any?
      reasons << "no tests to run" if tests["status"] == "none"
      reasons << "tests failed: #{tests['commands'].last['command']}" if tests["status"] == "failed"
      reasons
    end

    # GitHub's checks on the PR: wait while any are pending (a repo with none
    # has the forge's own test run to go on).
    def checks_blockers(url)
      deadline = @clock.call + @checks_wait
      first_seen = @clock.call
      loop do
        state = checks_state(url)
        return [] if state == "pass"
        return [ "GitHub checks failed" ] if state == "fail"
        return [] if state == "none" && @clock.call - first_seen >= 2 * @poll # none ever registered
        return [ "GitHub checks still pending after #{@checks_wait}s" ] if @clock.call >= deadline

        @sleeper.call(@poll)
      end
    end

    # pass | fail | pending | none
    def checks_state(url)
      status, out, = gh("pr", "checks", url, "--json", "bucket")
      buckets = (JSON.parse(out) rescue nil)
      return (status.zero? ? "none" : "pending") unless buckets.is_a?(Array)
      return "none" if buckets.empty?
      return "fail" if buckets.any? { |c| %w[fail cancel].include?(c["bucket"]) }
      return "pending" if buckets.any? { |c| c["bucket"] == "pending" }

      "pass"
    end

    def merge(url, blockers)
      say "merging #{url}"
      status, out, err = gh("pr", "merge", url, "--squash", "--delete-branch")
      return true if status.zero?

      blockers << "GitHub refused the merge: #{(err.strip.empty? ? out : err).strip.lines.first.to_s.strip}"
      false
    end

    # --- GitHub --------------------------------------------------------------

    def push
      say "pushing #{branch}"
      git! %w[push --quiet --force -u origin], branch
    end

    # A fresh PR, or the open one for this branch with its body brought up to date.
    def open_pull_request(outcome, changes, tests, majors_available)
      body = pr_body(outcome, changes, tests, majors_available)
      status, out, err = run([ "gh", "pr", "create", "--base", base, "--head", branch, "--title", pr_title, "--body-file", "-" ],
                             chdir: dir, stdin: body)
      if status != 0 && (err + out).include?("already exists")
        run([ "gh", "pr", "edit", branch, "--title", pr_title, "--body-file", "-" ], chdir: dir, stdin: body)
        status, out, err = run(%w[gh pr view --json url --jq .url], chdir: dir)
      end
      raise Error, "gh pr create failed: #{(err.strip.empty? ? out : err).strip}" unless status.zero?

      url = out.lines.map(&:strip).reverse.find { |l| l.start_with?("https://") }
      raise Error, "gh did not print a PR URL: #{out.strip}" if url.nil?

      url
    end

    def cleanup
      FileUtils.rm_rf(dir)
    end

    # --- text ----------------------------------------------------------------

    def pr_title
      scope == "minor" ? "Upkeep: patch and minor upgrades" : "Upkeep: a major upgrade"
    end

    def brief
      common = <<~COMMON
        You are in a fresh clone of **#{repo}** (branch `#{branch}`, from `#{base}`), one of the
        apps a household runs on its own server. hob, the household's assistant, keeps them
        current. Find every stack in the repo (Gemfile, package.json, pyproject.toml, and so
        on) and work in each.

        Commit your work, in as many commits as make sense, each message ending with the line
        `#{CO_AUTHOR}`. Do not push and do not open a pull request; the forge does that, and it
        decides on its own whether the result may merge: it re-reads the lockfiles and runs the
        tests itself.

        ## Do not

        - Touch secrets, credentials, `.env*` files, deploy configuration (Coolify, Kamal,
          Docker Compose), CI workflows, or the database beyond what the test suite needs.
        - Add new dependencies, or remove ones the app uses.
        - Call hosts other than the package registries and GitHub.
        - Edit or delete `.forge/`.

        If the repo cannot be upgraded safely from here (it will not install, its tests cannot
        run in this sandbox, or the work needs a person's decision), write why to
        `.forge/REFUSED.md` and stop without committing.

        ## Commands

        Read files with your Read, Glob, and Grep tools. Your shell runs only these commands,
        matched against the start of the whole line (`…` takes any arguments):

        #{commands_allowed}

        Run each on its own, from the repo root where you start: no `cd`, `&&`, `;`, pipes, or
        `VAR=value` prefixes, any of which keeps the line from matching. A command that comes back
        "requires approval" is only one not on this list; nobody can approve it, and it says
        nothing about whether the tool works here. Use a listed command instead, and never refuse
        on the strength of a refused command alone.
      COMMON
      if scope == "minor"
        <<~BRIEF
          # Upkeep: patch and minor upgrades for #{repo}

          #{common}
          ## Do

          1. Take every dependency to the newest release **within its current major version**,
             changing only lockfiles: Ruby `bundle update --minor --strict` (then `bundle install`);
             Node `npm update` without editing the ranges in package.json; Python `uv lock --upgrade`
             (or the project's own tool) without editing the constraints in pyproject.toml.
          2. Run the tests the repo has. If an upgrade breaks them, hold that one dependency back
             (and say which, and why, in your summary) rather than changing application code.
          3. Do not upgrade across a major version, the language runtime (.ruby-version,
             .nvmrc, .python-version, engines), or a Docker base image here. Instead, list what has a
             newer major release in `.forge/MAJORS.md`, one line each: `name current → latest`,
             frameworks and runtimes first (`bundle outdated`, `npm outdated`, `uv tree --outdated`).
          4. If nothing needs upgrading, commit nothing.

          Reply with a short summary: what moved, what was held back and why.
        BRIEF
      else
        <<~BRIEF
          # Upkeep: one major upgrade for #{repo}

          #{common}
          ## Do

          1. Find what is behind by a major version: frameworks (Rails, Next, Vite, FastAPI ...),
             the language runtime, and libraries (`bundle outdated`, `npm outdated`,
             `uv tree --outdated`).
          2. Pick **one** upgrade: the framework if it is behind, else the runtime, else the
             library whose age matters most. Do it fully: the version bump, the code and
             configuration changes its upgrade guide calls for (`bin/rails app:update` for Rails,
             reviewing each change), deprecations it raises in the tests.
          3. The tests must pass at the end. If they cannot without a decision a person should
             make, write that to `.forge/REFUSED.md` instead.
          4. List the other majors still waiting in `.forge/MAJORS.md`, one line each.

          This branch is always reviewed by a person. Reply with a summary for them: what you
          upgraded, what changed in the code and why, and what to check by hand after deploying.
        BRIEF
      end
    end

    # The shell commands @claude_args allow, for the brief: "`bundle update …`".
    def commands_allowed
      @claude_args.filter_map { |a| a[/\ABash\((.+)\)\z/, 1] }.map { |c| "`#{c.sub(/:\*\z/, ' …')}`" }.join(", ")
    end

    def pr_body(outcome, changes, tests, majors_available)
      moved = changes.map { |c| "| #{c['name']} | #{c['from']} | #{c['to']} |#{' **major**' if c['major']}" }
      test_lines = tests["commands"].map { |c| "- #{c['ok'] ? '✅' : '❌'} `#{c['command']}`" }
      failure = tests["commands"].find { |c| !c["ok"] }
      <<~BODY
        hob's forge keeps #{repo} current (`forge.upkeep`, scope **#{scope}**).#{' It merges this itself when only lockfiles changed, no version crossed a major, the tests passed, and no check failed; otherwise it waits for you.' if scope == 'minor'}

        ## What moved

        #{moved.empty? ? '(no lockfile versions moved)' : "| dependency | from | to |\n|---|---|---|\n#{moved.join("\n")}"}

        ## Tests (run by the forge)

        #{test_lines.empty? ? 'No test suite found to run.' : test_lines.join("\n")}
        #{failure ? "\n```\n#{failure['output']}\n```\n" : ''}
        #{majors_available.empty? ? '' : "## Majors waiting\n\n#{majors_available}\n"}
        ## Implementer's summary

        #{outcome['result'].to_s.strip}

        _#{outcome['num_turns']} turns, $#{outcome['total_cost_usd']}. This branch is rebuilt and force-pushed on every upkeep run._

        🤖 Generated with [Claude Code](https://claude.com/claude-code)
      BODY
    end

    def summary(status, url, changes, blockers, dependabot)
      moved = "#{changes.size} version(s) moved"
      merged = dependabot.any? ? "; merged #{dependabot.size} Dependabot PR(s)" : ""
      if status == "merged"
        "#{repo}: merged #{url} (#{moved})#{merged}"
      else
        "#{repo}: #{url} needs review: #{blockers.join('; ')}#{merged}"
      end
    end

    def result(status, outcome, url: nil, merged: false, review: [], tests: nil, changes: [], dependabot: [],
               majors_available: "", summary: "")
      {
        "repo" => repo, "scope" => scope, "status" => status, "pull_request" => url, "merged" => merged,
        "review" => review, "tests" => tests, "changes" => changes, "dependabot" => dependabot,
        "majors_available" => majors_available.empty? ? nil : majors_available,
        "summary" => summary, "implementer" => (excerpt(outcome["result"].to_s.strip) unless outcome["result"].to_s.strip.empty?),
        "cost" => outcome["total_cost_usd"], "notify" => status == "review"
      }.compact
    end

    # --- lockfile parsers: name -> version -----------------------------------

    def gemfile_lock(text)
      text.scan(/^    ([^\s(]+) \(([^)]+)\)$/).each_with_object({}) do |(name, version), h|
        h[name] ||= version.sub(/-(?:x86|arm|aarch|universal|java|x64)[\w-]*\z/, "")
      end
    end

    def package_lock(text)
      packages = (JSON.parse(text)["packages"] rescue nil) || {}
      packages.each_with_object({}) do |(path, info), h|
        next if path.empty? || !info.is_a?(Hash) || info["version"].nil?

        h[path.sub(/\A.*node_modules\//, "")] ||= info["version"] if path.scan("node_modules/").size == 1
      end
    end

    def toml_lock(text)
      text.scan(/^\[\[package\]\]\s*\nname = "([^"]+)"\s*\nversion = "([^"]+)"/).to_h
    end

    # The names the app depends on itself, before or after; nil when the
    # lockfile does not say (uv.lock and poetry.lock, without a TOML parser).
    def direct_dependencies(file, *texts)
      case File.basename(file)
      when "Gemfile.lock"
        texts.flat_map { |t| t[/^DEPENDENCIES\n(.*?)(?:\n\n|\z)/m, 1].to_s.scan(/^  ([^\s(!]+)/).flatten }
      when "package-lock.json"
        texts.flat_map do |t|
          root = ((JSON.parse(t)["packages"] rescue nil) || {})[""] || {}
          %w[dependencies devDependencies optionalDependencies peerDependencies].flat_map { |k| (root[k] || {}).keys }
        end
      end
    end

    # --- plumbing ------------------------------------------------------------

    def file?(rel)
      File.file?(File.join(dir, rel))
    end

    def read(rel)
      path = File.join(dir, rel)
      File.file?(path) ? File.read(path) : ""
    end

    def read_forge_file(name)
      read(File.join(".forge", name)).strip
    end

    def parse_outcome(out)
      data = JSON.parse(out)
      data.is_a?(Array) ? (data.find { |d| d.is_a?(Hash) && d["type"] == "result" } || {}) : data
    rescue JSON::ParserError
      { "result" => out }
    end

    def run(argv, chdir:, stdin: nil)
      @runner.call(argv, chdir: chdir, stdin: stdin)
    end

    def gh(*argv, chdir: nil)
      run([ "gh", *argv ], chdir: chdir || (File.directory?(dir) ? dir : workdir))
    end

    def git(argv, *rest)
      run([ "git", *argv, *rest ], chdir: dir)
    end

    def git!(argv, *rest)
      status, out, err = git(argv, *rest)
      raise Error, "git #{argv.first} failed: #{(err.strip.empty? ? out : err).strip}" unless status.zero?

      out
    end

    def excerpt(text, limit = 2000)
      text = text.to_s.strip
      return text if text.length <= limit

      half = limit / 2
      "#{text[0, half]}\n[... #{text.length - limit} characters elided ...]\n#{text[-half..]}"
    end

    def say(message)
      log.puts("[forge #{Time.now.utc.iso8601}] #{repo} (#{scope}): #{message}") if log
    end
  end
end
