require "test_helper"

# The forge, with every command faked: what it runs, in what order, and what
# it makes of the answers. Hob::Fake stands in for hob.
class ForgeTest < ActiveSupport::TestCase
  setup do
    $LOAD_PATH.unshift(Rails.root.join("clients/ruby/lib").to_s) unless $LOAD_PATH.include?(Rails.root.join("clients/ruby/lib").to_s)
    require "hob"
    require "hob/fake"
    @root = Dir.mktmpdir("forge-test")
    @repo = File.join(@root, "hob")
    @workdir = File.join(@root, "worktrees")
    FileUtils.mkdir_p(File.join(@repo, ".git", "info"))
    FileUtils.mkdir_p(File.join(@repo, ".bundle"))
    File.write(File.join(@repo, ".bundle", "config"), "BUNDLE_PATH: x\n")
    @commands = []
    @answers = Hash.new { |_h, k| [ 0, "", "" ] }
  end

  teardown { FileUtils.rm_rf(@root) }

  def payload(spec_overrides = {})
    { "kind" => "forge.capability", "petition" => "01J8Z4ABCDEF", "agent" => "muse", "want" => "read the calendar",
      "reason" => "planning", "effect" => "allow", "rationale" => "nothing reads it yet",
      "spec" => { "name" => "hob.calendar.read", "description" => "Read the household calendar.", "kind" => "read",
                  "realm" => "household", "input_schema" => { "type" => "object", "properties" => { "from" => { "type" => "string" } } },
                  "behaviour" => "Query events between from and to.", "result" => { "events" => [] },
                  "acceptance" => [ "returns events", "rejects missing from" ], "notes" => "" }.merge(spec_overrides) }
  end

  # A runner that records commands and fakes the ones the build depends on:
  # worktree add creates the directory; claude answers JSON; git counts commits.
  def runner
    lambda do |argv, chdir:, stdin: nil|
      @commands << [ argv, chdir, stdin ]
      key = argv.take(3).join(" ")
      case key
      when /\Agit worktree add/
        FileUtils.mkdir_p(argv.last(2).first)
        [ 0, "", "" ]
      when /\Agit status --porcelain/ then @answers["status"]
      when /\Agit rev-list --count/ then @answers.fetch("rev-list", [ 0, "1\n", "" ])
      when /\Agit diff --name-only/ then @answers.fetch("diff", [ 0, "app/services/sentinel/native/calendar_read.rb\ntest/x_test.rb\n", "" ])
      when /\Agit rev-parse HEAD/ then [ 0, "abc123\n", "" ]
      when /\Aclaude -p/ then @answers.fetch("claude", [ 0, { "type" => "result", "result" => "Built it.", "num_turns" => 12, "total_cost_usd" => 0.42 }.to_json, "" ])
      when /\Abin\/rails test/ then @answers.fetch("test", [ 0, "10 runs, 0 failures\n", "" ])
      when /\Abundle check/ then @answers.fetch("bundle check", [ 0, "", "" ])
      when /\Abundle install/ then @answers.fetch("bundle install", [ 0, "", "" ])
      when /\Aenv RAILS_ENV=test bin\/rails/
        argv.include?("db:migrate") ? @answers.fetch("migrate", [ 0, "", "" ]) : @answers.fetch("prepare", [ 0, "", "" ])
      when /\Agit diff --quiet/ then @answers.fetch("structure", [ 0, "", "" ])
      when /\Agh pr create/ then @answers.fetch("gh", [ 0, "https://github.com/jenrzzz/hob/pull/9\n", "" ])
      else [ 0, "", "" ]
      end
    end
  end

  def build(payload = self.payload, **opts)
    Forge::Build.new(payload: payload, repo: @repo, workdir: @workdir, runner: runner, log: nil, **opts)
  end

  test "a build: fresh worktree, brief on stdin, claude, tests, push, PR" do
    result = build.call
    assert_equal "https://github.com/jenrzzz/hob/pull/9", result["pull_request"]
    assert_equal "forge/hob-calendar-read-abcdef", result["branch"]
    assert_equal "hob.calendar.read", result["capability"]
    assert_equal "abc123", result["commit"]
    assert_equal "Built it.", result["summary"]
    assert_equal 0.42, result["cost"]

    names = @commands.map { |argv, _, _| argv.take(3).join(" ") }
    assert_equal "git fetch --quiet", names[0]
    assert_match(/\Agit worktree add/, names[1])
    dir = File.join(@workdir, "forge-hob-calendar-read-abcdef")
    assert_equal dir, @commands[1][0].last(2).first
    assert_equal @repo, @commands[1][1], "worktree ops run in the main checkout"
    assert File.file?(File.join(dir, ".bundle", "config")), "local config is copied in"
    assert_match(/\.forge\//, File.read(File.join(@repo, ".git", "info", "exclude")))
    assert File.file?(File.join(dir, ".forge", "SPEC.json"))

    claude = @commands.find { |argv, _, _| argv.first == "claude" }
    assert_equal dir, claude[1]
    assert_includes claude[0], "--output-format"
    assert_includes claude[0], "acceptEdits"
    assert_includes claude[0], "Bash(bin/rails test:*)"
    brief = claude[2]
    assert_match(/implement the sentinel capability `hob.calendar.read`/, brief)
    assert_match(/app\/services\/sentinel\/native\/calendar_read.rb/, brief)
    assert_match(/Sentinel::Native::CalendarRead < Base/, brief)
    assert_match(/"behaviour": "Query events between from and to."/, brief)
    assert_match(/> want: read the calendar/, brief)
    assert_match(/Co-Authored-By: Claude Fable 5.1/, brief)
    assert_match(/REFUSED.md/, brief)

    names_after_claude = @commands.drop_while { |argv, _, _| argv.first != "claude" }.map { |argv, _, _| argv.join(" ") }
    assert_equal [ "bundle check", "env RAILS_ENV=test bin/rails db:test:prepare", "bin/rails test" ],
                 names_after_claude.grep(/\A(bundle|env|bin\/rails) /), "gems and the test database are prepared, then the suite runs"
    assert_nil @commands.find { |argv, _, _| argv[0..1] == %w[bundle install] }, "gems present: no install"
    push = @commands.find { |argv, _, _| argv[0..1] == %w[git push] }
    assert_includes push[0], "forge/hob-calendar-read-abcdef"
    pr = @commands.find { |argv, _, _| argv[0..1] == %w[gh pr] }
    assert_equal "Add sentinel capability hob.calendar.read", pr[0][pr[0].index("--title") + 1]
    body = pr[2]
    assert_match(/petition `01J8Z4ABCDEF` from \*\*muse\*\*/, body)
    assert_match(/muse → `hob.calendar.read` at `allow`/, body)
    assert_match(/- \[ \] returns events/, body)
    assert_match(/Built it\./, body)
    assert_match(/Generated with \[Claude Code\]/, body)
    assert_equal %w[git worktree remove], @commands.last[0].take(3)
  end

  test "uncommitted work is committed by the forge; no commits at all fails" do
    @answers["status"] = [ 0, " M app/services/sentinel/native/calendar_read.rb\n?? .forge/\n", "" ]
    build.call
    commit = @commands.find { |argv, _, _| argv[0..1] == %w[git commit] }
    assert_match(/\AAdd hob.calendar.read: Read the household calendar\./, commit[0].last)
    assert_match(/petition 01J8Z4ABCDEF/, commit[0].last)

    @commands.clear
    @answers["status"] = [ 0, "", "" ]
    @answers["rev-list"] = [ 0, "0\n", "" ]
    error = assert_raises(Forge::Error) { build.call }
    assert_match(/no commits/, error.message)
    assert_nil @commands.find { |argv, _, _| argv[0..1] == %w[git push] }
  end

  test "failures: claude errors, a refusal, failing tests, no handler, gh trouble" do
    @answers["claude"] = [ 1, { "type" => "result", "is_error" => true, "result" => "context blew up" }.to_json, "" ]
    assert_match(/claude exited 1: context blew up/, assert_raises(Forge::Error) { build.call }.message)

    @answers.delete("claude")
    b = build
    refusing = lambda do |argv, chdir:, stdin: nil|
      if argv.first == "claude"
        FileUtils.mkdir_p(File.join(chdir, ".forge"))
        File.write(File.join(chdir, ".forge", "REFUSED.md"), "The spec wants raw shell access.")
      end
      runner.call(argv, chdir: chdir, stdin: stdin)
    end
    b.instance_variable_set(:@runner, refusing)
    error = assert_raises(Forge::Refused) { b.call }
    assert_match(/raw shell access/, error.message)
    assert_nil @commands.find { |argv, _, _| argv[0..1] == %w[git push] }

    @answers["test"] = [ 1, "12 runs, 2 failures\n", "" ]
    assert_match(/tests failed after the build:\n12 runs, 2 failures/, assert_raises(Forge::Error) { build.call }.message)
    @answers.delete("test")

    @answers["diff"] = [ 0, "SENTINEL.md\n", "" ]
    assert_match(/no native handler was added/, assert_raises(Forge::Error) { build.call }.message)
    @answers.delete("diff")

    @answers["gh"] = [ 1, "", "permission denied" ]
    assert_match(/gh pr create failed: permission denied/, assert_raises(Forge::Error) { build.call }.message)
  end

  test "a build that adds a migration migrates the test database and commits the schema dump" do
    build.call
    assert_nil @commands.find { |argv, _, _| argv.include?("db:migrate") }, "no migration: no migrate"

    @answers["diff"] = [ 0, "app/services/sentinel/native/calendar_read.rb\ndb/migrate/20260921000001_create_events.rb\ndb/structure.sql\n", "" ]
    @answers["structure"] = [ 1, "", "" ]
    @commands.clear
    build.call
    names = @commands.map { |argv, _, _| argv.join(" ") }
    migrate = names.index("env RAILS_ENV=test bin/rails db:migrate")
    assert migrate, "migrates the test database"
    assert_operator names.index("env RAILS_ENV=test bin/rails db:test:prepare"), :<, migrate
    assert_operator migrate, :<, names.index("bin/rails test"), "before the tests"
    assert_includes names, "git add -- db/structure.sql"
    commit = @commands.find { |argv, _, _| argv.take(3) == %w[git commit --quiet] && argv.last.start_with?("Dump the schema") }
    assert commit, "commits the dump"
    assert_match(/20260921000001_create_events.rb/, commit[0].last)
    assert_operator @commands.index(commit), :<, @commands.index { |argv, _, _| argv.take(2) == %w[git push] }

    @answers["structure"] = [ 0, "", "" ]
    @commands.clear
    build.call
    assert_nil @commands.find { |argv, _, _| argv.take(3) == %w[git add --] }, "unchanged dump: nothing to commit"

    @answers["migrate"] = [ 1, "", "PG::UndefinedTable: relation does not exist" ]
    assert_match(/could not migrate the test database:\nPG::UndefinedTable/, assert_raises(Forge::Error) { build.call }.message)
  end

  test "a worktree missing gems installs them; a database that will not prepare fails the build" do
    @answers["bundle check"] = [ 1, "", "missing" ]
    build.call
    assert @commands.find { |argv, _, _| argv[0..2] == %w[bundle install --quiet] }

    @answers["bundle install"] = [ 1, "", "no route to rubygems" ]
    assert_match(/bundle install failed:\nno route to rubygems/, assert_raises(Forge::Error) { build.call }.message)

    # Bundler leads with the error and follows it with the whole Gemfile and lockfile: the
    # message keeps both ends, so the error survives the mission's own truncation.
    @answers["bundle install"] = [ 1, "", "Net::HTTPClientException: 403 \"Forbidden\"\n--- ERROR REPORT TEMPLATE ---\n#{"  zeitwerk (2.8.2) sha256=7212a6\n" * 200}--- TEMPLATE END ---" ]
    message = assert_raises(Forge::Error) { build.call }.message
    assert_match(/bundle install failed:\nNet::HTTPClientException: 403 "Forbidden"\n/, message)
    assert_match(/\n\[\.\.\. \d+ characters elided \.\.\.\]\n/, message)
    assert_match(/--- TEMPLATE END ---\z/, message)
    assert_operator message.length, :<, 2200
    @answers.delete("bundle install")
    @answers.delete("bundle check")

    @commands.clear
    @answers["prepare"] = [ 1, "", "could not connect to server" ]
    assert_match(/could not prepare the test database:\ncould not connect/, assert_raises(Forge::Error) { build.call }.message)
    assert_nil @commands.find { |argv, _, _| argv == %w[bin/rails test] }
  end

  test "the payload is checked before anything runs" do
    assert_match(/not a forge.capability mission/, assert_raises(Forge::Error) { build({ "kind" => "other" }) }.message)
    assert_match(/no name/, assert_raises(Forge::Error) { build(payload("name" => nil)) }.message)
    assert_match(/not a capability name/, assert_raises(Forge::Error) { build(payload("name" => "Bad Name")) }.message)
    assert_empty @commands
  end

  test "the worker leases, heartbeats, completes, and fails missions through hob" do
    hob = Hob::Fake.new
    hob.missions.create(assignee: "forge", title: "Build capability hob.calendar.read", payload: payload)
    hob.missions.create(assignee: "forge", title: "Build something else", payload: payload("name" => "hob.other.do"))
    built = []
    ids = []
    factory = lambda do |payload, id|
      built << payload["spec"]["name"]
      ids << id
      raise Forge::Error, "tests failed" if payload["spec"]["name"] == "hob.other.do"

      Struct.new(:result) { def call = result }.new({ "pull_request" => "https://github.com/x/hob/pull/1", "capability" => payload["spec"]["name"] })
    end
    worker = Forge::Worker.new(hob: hob, repo: @repo, workdir: @workdir, heartbeat: 0, log: nil, build: factory)
    assert_equal 2, worker.work(wait: 0, drain: true)
    assert_equal [ "hob.calendar.read", "hob.other.do" ], built
    assert_equal hob.missions.list.map(&:id), ids, "the factory gets the mission's id, which names its workspace"
    done, failed = hob.missions.list
    assert_equal "completed", done.status
    assert_equal "https://github.com/x/hob/pull/1", done.result["pull_request"]
    assert_equal "failed", failed.status
    assert_match(/Error: tests failed/, failed.error)
    assert_equal 0, worker.work(wait: 0, once: true), "an empty queue with --once returns"
  end

  # --- in a Coder workspace ---------------------------------------------------

  # A runner that fakes the coder CLI: `create` and `delete` succeed, `ssh`
  # answers the poll with PENDING a few times and then with the report (or,
  # with `dead`, with DEAD from then on, and the build's log when asked).
  def coder_runner(report, pending: 2, create: [ 0, "", "" ], ssh_failures: 0, dead: false, log: "", list: [], started: true)
    polls = 0
    lambda do |argv, chdir:, stdin: nil|
      @commands << [ argv, chdir, stdin ]
      case argv.take(2).join(" ")
      when "coder list" # names the sandbox has, or a raw [status, out, err]
        list.all?(String) ? [ 0, list.map { |n| { "name" => n, "status" => "running" } }.to_json, "" ] : list
      when "coder create" then create
      when "coder delete" then [ 0, "", "" ]
      when "coder ssh"
        command = argv.last
        if command.include?("build.pid -o -e")
          [ 0, started ? "STARTED\n" : "FRESH\n", "" ]
        elsif command.include?("result.json 2>/dev/null")
          polls += 1
          next [ 255, "", "dial tcp: connection refused" ] if polls <= ssh_failures

          next [ 0, "PENDING\n", "" ] if polls - ssh_failures <= pending
          next [ 0, "DEAD\n", "" ] if dead

          [ 0, report.is_a?(String) ? report : report.to_json, "" ]
        elsif command.include?("build.log 2>/dev/null")
          [ 0, log, "" ]
        else
          [ 0, "", "" ]
        end
      else [ 1, "", "unexpected #{argv.inspect}" ]
      end
    end
  end

  def workspace(report, runner: nil, clock: nil, **opts)
    Forge::Workspace.new(payload: payload, runner: runner || coder_runner(report), log: nil, poll: 0,
                         clock: clock || -> { Time.at(1_700_000_000) }, **opts)
  end

  test "a workspace build: create, copy the payload in, start detached, poll, delete" do
    built = { "ok" => true, "pull_request" => "https://github.com/jenrzzz/hob/pull/9", "branch" => "forge/hob-calendar-read-abcdef",
              "capability" => "hob.calendar.read", "commit" => "abc123", "summary" => "Built it.", "cost" => 0.42 }
    ws = workspace(built)
    assert_equal "forge-abcdef", ws.name, "named for the petition when no mission id is given"
    assert_equal "forge-01jx9abc", workspace(built, mission: "01JX9ABC").name, "named for the mission's id tail"

    result = ws.call
    assert_equal built.except("ok"), result

    listing = @commands[0][0]
    assert_equal [ "coder", "list", "--output", "json", "--search", "name:#{ws.name}" ], listing, "first, whether an earlier run left it"
    create = @commands[1][0]
    assert_equal %w[coder create], create.take(2)
    assert_equal ws.name, create[2]
    assert_includes create, "--template"
    assert_equal "agent-workspace", create[create.index("--template") + 1]
    assert_includes create, "repo=jenrzzz/hob"
    assert_includes create, "branch=main"
    assert_includes create, "image=ghcr.io/jenrzzz/agent-workspace-hob:latest"
    assert_includes create, "--yes"
    assert_includes create, "--use-parameter-defaults", "or coder prompts for the template's other parameters on an empty stdin"

    upload = @commands[2]
    assert_equal [ "coder", "ssh", "--wait=yes", ws.name, "--" ], upload[0].take(5), "the first ssh waits for the clone"
    assert_match(%r{cat > /home/node/forge/payload.json}, upload[0].last)
    assert_equal payload, JSON.parse(upload[2]), "the payload goes in on stdin"

    start = @commands[3][0]
    assert_equal "--wait=no", start[2]
    assert_equal "cd /workspace && setsid nohup sh -c 'echo $$ > /home/node/forge/build.pid; exec forge-env bin/forge build " \
                 "--payload /home/node/forge/payload.json --result /home/node/forge/result.json --workdir /home/node/forge/worktrees " \
                 "--base main' > /home/node/forge/build.log 2>&1 < /dev/null &", start.last, "the shell records its pid, then becomes the build"

    polls = @commands.select { |argv, _, _| argv[1] == "ssh" && argv.last.include?("result.json 2>/dev/null") }
    assert_equal 3, polls.size, "two PENDING answers, then the report"
    assert_equal [ "coder", "delete", ws.name, "--yes" ], @commands.last[0]
    assert @commands.all? { |argv, _, _| argv.first == "coder" }, "the loop's box only ever runs coder"
  end

  test "a workspace an earlier run left behind is adopted: no second build, just the polling and the delete" do
    built = { "ok" => true, "pull_request" => "https://github.com/jenrzzz/hob/pull/9" }
    ws = workspace(built, mission: "01M31CZEXF4GWZWA0F8RHP3AKK", runner: coder_runner(built, pending: 1, list: %w[forge-other forge-8rhp3akk]))
    assert_equal "forge-8rhp3akk", ws.name
    assert_equal built.except("ok"), ws.call
    names = @commands.map { |argv, _, _| argv.take(2).join(" ") }
    assert_nil names.index("coder create"), "the build already ran, or is running, in there"
    assert_nil @commands.find { |argv, _, _| argv.last.to_s.include?("payload.json") }, "no second payload"
    assert_nil @commands.find { |argv, _, _| argv.last.to_s.include?("setsid nohup") }, "no second build"
    assert_equal 2, @commands.count { |argv, _, _| argv.last.to_s.include?("result.json 2>/dev/null") }, "polled to the report"
    assert_equal [ "coder", "delete", ws.name, "--yes" ], @commands.last[0]

    # Left behind before its build was started: the payload goes in and the build starts, in the same workspace.
    @commands.clear
    fresh = workspace(built, mission: "01M31CZEXF4GWZWA0F8RHP3AKK", runner: coder_runner(built, pending: 0, list: %w[forge-8rhp3akk], started: false))
    assert_equal built.except("ok"), fresh.call
    names = @commands.map { |argv, _, _| argv.take(2).join(" ") }
    assert_nil names.index("coder create")
    assert @commands.find { |argv, _, _| argv.last.to_s.include?("payload.json") }
    assert @commands.find { |argv, _, _| argv.last.to_s.include?("setsid nohup") }

    # A listing that fails is not "no workspace": nothing is created, and nothing is deleted.
    @commands.clear
    error = assert_raises(Forge::Error) { workspace(built, runner: coder_runner(built, list: [ 1, "", "unauthorized" ])).call }
    assert_match(/coder list failed: unauthorized/, error.message)
    assert_equal 1, @commands.size, "the listing was the only call"

    @commands.clear
    error = assert_raises(Forge::Error) { workspace(built, runner: coder_runner(built, list: [ 0, "<html>", "" ])).call }
    assert_match(/coder list did not print JSON/, error.message)
    assert_equal 1, @commands.size
  end

  test "a failed or refused build raises what the workspace reported, and the workspace is still deleted" do
    error = assert_raises(Forge::Error) { workspace({ "ok" => false, "kind" => "Error", "error" => "tests failed after the build:\n2 failures" }).call }
    assert_equal "tests failed after the build:\n2 failures", error.message
    assert_equal %w[coder delete], @commands.last[0].take(2)

    @commands.clear
    assert_raises(Forge::Refused) { workspace({ "ok" => false, "kind" => "Refused", "error" => "the implementer refused: raw shell" }).call }
    assert_equal %w[coder delete], @commands.last[0].take(2)

    @commands.clear
    assert_raises(Forge::Error) { workspace({ "ok" => false, "kind" => "Error", "error" => "x" }, keep: true).call }
    assert_nil @commands.find { |argv, _, _| argv[1] == "delete" }, "--keep leaves a failed workspace for a look"

    @commands.clear
    workspace({ "ok" => true, "pull_request" => "u" }, keep: true).call
    assert_equal %w[coder delete], @commands.last[0].take(2), "--keep deletes a workspace whose build succeeded"
  end

  test "a workspace that cannot be created, is lost, or times out fails the build" do
    error = assert_raises(Forge::Error) { workspace({}, runner: coder_runner({}, create: [ 1, "", "template not found" ])).call }
    assert_match(/coder create failed: template not found/, error.message)
    assert_equal %w[coder delete], @commands.last[0].take(2), "even a failed create is cleaned up"

    @commands.clear
    ws = workspace({ "ok" => true, "pull_request" => "u" }, runner: coder_runner({ "ok" => true, "pull_request" => "u" }, pending: 0, ssh_failures: 3))
    assert_equal({ "pull_request" => "u" }, ws.call, "a few unreachable polls are retried")

    @commands.clear
    lost = workspace({}, runner: coder_runner({}, pending: 0, ssh_failures: Forge::Workspace::LOST))
    assert_match(/lost workspace forge-abcdef: dial tcp/, assert_raises(Forge::Error) { lost.call }.message)

    @commands.clear
    ticks = [ 0, 0, 0, 5000 ].map { |t| Time.at(1_700_000_000 + t) }
    slow = workspace({}, runner: coder_runner({}, pending: 50), clock: -> { ticks.size > 1 ? ticks.shift : ticks.first }, timeout: 3600)
    assert_match(/did not finish within 3600s/, assert_raises(Forge::Error) { slow.call }.message)

    @commands.clear
    assert_match(/report is not JSON/, assert_raises(Forge::Error) { workspace("<html>", runner: coder_runner("<html>", pending: 0)).call }.message)
  end

  test "a build whose process is gone with no report fails with the end of its log, not after three hours" do
    gone = coder_runner({}, pending: 1, dead: true, log: "/usr/local/bin/forge-env: line 47: /workspace/bin/forge: No such file or directory\n")
    error = assert_raises(Forge::Error) { workspace({}, runner: gone).call }
    assert_match(/\Athe build in forge-abcdef died without a report:\n.*bin\/forge: No such file or directory\z/, error.message)
    polls = @commands.select { |argv, _, _| argv.last.include?("result.json 2>/dev/null") }
    assert_equal 1 + Forge::Workspace::DEAD, polls.size, "one PENDING, then DEAD twice: a single DEAD may be a poll racing the start"
    assert_match(/kill -0 "\$\(cat \/home\/node\/forge\/build.pid/, polls.last[0].last, "the poll looks for the build's process")
    assert_equal %w[coder delete], @commands.last[0].take(2)

    @commands.clear
    flicker = 0
    once = lambda do |argv, chdir:, stdin: nil|
      @commands << [ argv, chdir, stdin ]
      next [ 0, "[]", "" ] if argv[1] == "list"
      next [ 0, "", "" ] unless argv[1] == "ssh" && argv.last.include?("result.json 2>/dev/null")

      flicker += 1
      case flicker
      when 1 then [ 0, "DEAD\n", "" ]
      when 2 then [ 0, "PENDING\n", "" ]
      when 3 then [ 0, "DEAD\n", "" ]
      else [ 0, { "ok" => true, "pull_request" => "u" }.to_json, "" ]
      end
    end
    assert_equal({ "pull_request" => "u" }, workspace({}, runner: once).call, "DEAD only counts in a row")

    @commands.clear
    silent = coder_runner({}, pending: 0, dead: true)
    assert_match(/died without a report:\n\(build.log is empty\)/, assert_raises(Forge::Error) { workspace({}, runner: silent).call }.message)
  end

  test "Forge.report turns a build's outcome or error into what bin/forge build writes" do
    ok = Struct.new(:result) { def call = result }.new({ "pull_request" => "u" })
    assert_equal({ "ok" => true, "pull_request" => "u" }, Forge.report(ok))
    refused = Object.new.tap { |o| o.define_singleton_method(:call) { raise Forge::Refused, "the implementer refused: no" } }
    assert_equal({ "ok" => false, "kind" => "Refused", "error" => "the implementer refused: no" }, Forge.report(refused))
    boom = Object.new.tap { |o| o.define_singleton_method(:call) { raise Errno::ENOENT, "claude" } }
    assert_equal "Error", Forge.report(boom)["kind"]
    assert_match(/Errno::ENOENT/, Forge.report(boom)["error"])
  end
end
