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

    assert_equal [ "bin/rails", "test" ], @commands.find { |argv, _, _| argv.first == "bin/rails" }[0]
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
    factory = lambda do |payload|
      built << payload["spec"]["name"]
      raise Forge::Error, "tests failed" if payload["spec"]["name"] == "hob.other.do"

      Struct.new(:result) { def call = result }.new({ "pull_request" => "https://github.com/x/hob/pull/1", "capability" => payload["spec"]["name"] })
    end
    worker = Forge::Worker.new(hob: hob, repo: @repo, workdir: @workdir, heartbeat: 0, log: nil, build: factory)
    assert_equal 2, worker.work(wait: 0, drain: true)
    assert_equal [ "hob.calendar.read", "hob.other.do" ], built
    done, failed = hob.missions.list
    assert_equal "completed", done.status
    assert_equal "https://github.com/x/hob/pull/1", done.result["pull_request"]
    assert_equal "failed", failed.status
    assert_match(/Error: tests failed/, failed.error)
    assert_equal 0, worker.work(wait: 0, once: true), "an empty queue with --once returns"
  end
end
