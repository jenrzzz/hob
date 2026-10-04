require "test_helper"

# Forge::Upkeep (SCHEDULES.md, "Upkeep") with every command faked: the clone
# is a real directory, the implementer writes real lockfiles, and the
# forge decides from those whether the PR may merge.
class ForgeUpkeepTest < ActiveSupport::TestCase
  OLD_GEMS = <<~LOCK.freeze
    GEM
      remote: https://rubygems.org/
      specs:
        nokogiri (1.18.1-x86_64-linux)
        pg (1.5.9)
        rails (8.1.3)
        zeitwerk (2.7.0)

    PLATFORMS
      x86_64-linux
  LOCK

  setup do
    $LOAD_PATH.unshift(Rails.root.join("lib").to_s) unless $LOAD_PATH.include?(Rails.root.join("lib").to_s)
    require "forge"
    @root = Dir.mktmpdir("upkeep-test")
    @workdir = File.join(@root, "work")
    @commands = []
    @answers = {}
    @checks = [ [ 0, "[]", "" ] ] # gh pr checks answers, in order; the last repeats
    @dependabot = []
    @files = { "Gemfile" => "gem 'rails'\n", "Gemfile.lock" => OLD_GEMS, "bin/rails" => "", "test/x_test.rb" => "" }
    @edits = { "Gemfile.lock" => OLD_GEMS.sub("rails (8.1.3)", "rails (8.1.4)").sub("pg (1.5.9)", "pg (1.6.0)") }
    @now = Time.utc(2026, 10, 1)
  end

  teardown { FileUtils.rm_rf(@root) }

  def payload(**over)
    { "kind" => "forge.upkeep", "repo" => "jenrzzz/airing", "branch" => "main", "scope" => "minor" }.merge(over.transform_keys(&:to_s))
  end

  def runner
    lambda do |argv, chdir:, stdin: nil|
      raise Errno::ENOENT, chdir unless File.directory?(chdir) # as Open3 does, in a fresh workspace
      @commands << [ argv, chdir, stdin ]
      line = argv.join(" ")
      case line
      when /\Agh repo clone (\S+) (\S+)/
        dir = Regexp.last_match(2)
        FileUtils.mkdir_p(File.join(dir, ".git", "info"))
        @files.each { |rel, body| FileUtils.mkdir_p(File.dirname(File.join(dir, rel))); File.write(File.join(dir, rel), body) }
        @clone = dir
        [ 0, "", "" ]
      when /\Agh pr list/ then [ 0, @dependabot.to_json, "" ]
      when /\Agh pr checks (\S+)/
        @answers.dig("checks", Regexp.last_match(1)) || (@checks.size > 1 ? @checks.shift : @checks.first)
      when /\Agh pr merge/ then @answers.fetch("merge", [ 0, "", "" ])
      when /\Agh pr create/ then @answers.fetch("create", [ 0, "https://github.com/jenrzzz/airing/pull/7\n", "" ])
      when /\Agh pr view/ then [ 0, "https://github.com/jenrzzz/airing/pull/6\n", "" ]
      when /\Aclaude -p/
        @edits.each { |rel, body| File.write(File.join(chdir, rel), body) }
        File.write(File.join(chdir, ".forge", "MAJORS.md"), @majors) if @majors
        File.write(File.join(chdir, ".forge", "REFUSED.md"), @refuse) if @refuse
        [ 0, { "type" => "result", "result" => "Bumped what moved.", "num_turns" => 9, "total_cost_usd" => 0.31 }.to_json, "" ]
      when /\Agit status --porcelain/ then [ 0, @edits.keys.map { |f| " M #{f}\n" }.join, "" ]
      when /\Agit diff --name-only/ then [ 0, @edits.keys.map { |f| "#{f}\n" }.join, "" ]
      when /\Agit rev-parse --abbrev-ref HEAD/ then [ 0, "main\n", "" ]
      when /\Agit show origin\/main:(\S+)/ then [ 0, @files.fetch(Regexp.last_match(1), ""), "" ]
      when /\Abin\/rails test/ then @answers.fetch("test", [ 0, "10 runs, 0 failures\n", "" ])
      else [ 0, "", "" ]
      end
    end
  end

  def upkeep(payload = self.payload, **opts)
    clock = -> { @now }
    sleeper = ->(s) { @now += s }
    Forge::Upkeep.new(payload: payload, workdir: @workdir, runner: runner, log: nil, poll: 30, checks_wait: 600,
                      clock: clock, sleeper: sleeper, **opts)
  end

  def ran?(pattern)
    @commands.any? { |argv, _, _| argv.join(" ").match?(pattern) }
  end

  test "minor: lockfile-only, within majors, tests pass, no CI: merged" do
    result = upkeep.call
    assert_equal "merged", result["status"], result["review"].inspect
    assert result["merged"]
    refute result["notify"]
    assert_equal "https://github.com/jenrzzz/airing/pull/7", result["pull_request"]
    assert_equal [ [ "pg", "1.5.9", "1.6.0", false ], [ "rails", "8.1.3", "8.1.4", false ] ],
                 result["changes"].map { |c| c.values_at("name", "from", "to", "major") }.sort
    assert_equal "passed", result["tests"]["status"]
    assert_equal [ "bundle install", "bin/rails test" ], result["tests"]["commands"].map { |c| c["command"] },
                 "no config/database.yml in this repo, so no db step"
    assert_match(/merged https:\/\/github.com\/jenrzzz\/airing\/pull\/7 \(2 version\(s\) moved\)/, result["summary"])

    assert ran?(/\Agh repo clone jenrzzz\/airing .*--branch main/)
    assert ran?(/\Agit checkout --quiet -B upkeep\/minor/)
    assert ran?(/\Agit push --quiet --force -u origin upkeep\/minor/)
    assert ran?(/\Agh pr merge https:\/\/github.com\/jenrzzz\/airing\/pull\/7 --squash --delete-branch/)
    brief = @commands.find { |argv, _, _| argv.first == "claude" }[2]
    assert_match(/bundle update --minor --strict/, brief)
    assert_match(/\.forge\/MAJORS.md/, brief)
    assert_includes @commands.find { |argv, _, _| argv.first == "claude" }[0], "Bash(npm update:*)"
    refute File.exist?(@clone), "the clone is cleaned up"
  end

  test "a major version in the lockfile leaves the PR for a person" do
    @edits["Gemfile.lock"] = OLD_GEMS.sub("rails (8.1.3)", "rails (9.0.0)")
    @majors = "rails 8.1.3 → 9.0.0"
    result = upkeep.call
    assert_equal "review", result["status"]
    assert result["notify"]
    assert_equal [ "major versions: rails 8.1.3 → 9.0.0" ], result["review"]
    assert_equal "rails 8.1.3 → 9.0.0", result["majors_available"]
    refute ran?(/\Agh pr merge/)
    body = @commands.find { |argv, _, _| argv.take(3) == %w[gh pr create] }[2]
    assert_match(/\| rails \| 8.1.3 \| 9.0.0 \| \*\*major\*\*/, body)
    assert_match(/## Majors waiting/, body)
  end

  test "changes beyond lockfiles, failed tests, or no tests at all each need a person" do
    @edits["Gemfile"] = "gem 'rails', '~> 9.0'\n"
    assert_match(/changes beyond lockfiles: Gemfile/, upkeep.call["review"].join)

    @edits.delete("Gemfile")
    @answers["test"] = [ 1, "1 failure\n", "" ]
    result = upkeep.call
    assert_equal [ "tests failed: bin/rails test" ], result["review"]
    assert_match(/1 failure/, @commands.reverse.find { |argv, _, _| argv.take(3) == %w[gh pr create] }[2])

    @answers.delete("test")
    @files.delete("test/x_test.rb")
    assert_equal [ "no tests to run" ], upkeep.call["review"]
  end

  test "nothing moved: current, no push, no PR" do
    @edits = {}
    result = upkeep.call
    assert_equal "current", result["status"]
    refute result["notify"]
    refute ran?(/\Agit push/)
    refute ran?(/\Agh pr create/)
  end

  test "waits out pending checks, merges on pass, leaves the PR on failure" do
    @checks = [ [ 8, [ { "bucket" => "pending" } ].to_json, "" ], [ 8, [ { "bucket" => "pending" } ].to_json, "" ],
                [ 0, [ { "bucket" => "pass" }, { "bucket" => "skipping" } ].to_json, "" ] ]
    assert_equal "merged", upkeep.call["status"]
    assert_equal Time.utc(2026, 10, 1, 0, 1), @now

    @checks = [ [ 1, [ { "bucket" => "fail" } ].to_json, "" ] ]
    assert_equal [ "GitHub checks failed" ], upkeep.call["review"]

    @checks = [ [ 8, [ { "bucket" => "pending" } ].to_json, "" ] ]
    assert_match(/still pending after 600s/, upkeep.call["review"].join)
  end

  test "a merge GitHub refuses (branch protection) is a review, with the reason" do
    @answers["merge"] = [ 1, "", "Pull request is not mergeable: review required\n" ]
    result = upkeep.call
    assert_equal "review", result["status"]
    assert_equal [ "GitHub refused the merge: Pull request is not mergeable: review required" ], result["review"]
  end

  test "an open PR for the branch is refreshed, not duplicated" do
    @answers["create"] = [ 1, "", "a pull request for branch \"upkeep/minor\" into branch \"main\" already exists" ]
    result = upkeep.call
    assert_equal "https://github.com/jenrzzz/airing/pull/6", result["pull_request"]
    assert ran?(/\Agh pr edit upkeep\/minor --title/)
  end

  test "minor first merges green Dependabot PRs within a major, and only those" do
    pr = ->(n, title) { { "number" => n, "title" => title, "url" => "https://github.com/jenrzzz/airing/pull/#{n}" } }
    @dependabot = [ pr.(1, "Bump puma from 6.4.0 to 6.5.0"), pr.(2, "Bump rails from 8.1.3 to 9.0.0"),
                    pr.(3, "Bump the npm group across 2 directories with 4 updates"), pr.(4, "Bump pg from 1.5.9 to 1.6.0") ]
    @answers["checks"] = { "https://github.com/jenrzzz/airing/pull/4" => [ 1, [ { "bucket" => "fail" } ].to_json, "" ],
                           "https://github.com/jenrzzz/airing/pull/1" => [ 0, [ { "bucket" => "pass" } ].to_json, "" ] }
    result = upkeep.call
    assert_equal [ { "name" => "puma", "from" => "6.4.0", "to" => "6.5.0", "pull_request" => "https://github.com/jenrzzz/airing/pull/1" } ],
                 result["dependabot"]
    merges = @commands.map { |argv, _, _| argv.join(" ") }.grep(/\Agh pr merge/)
    assert_equal [ "gh pr merge https://github.com/jenrzzz/airing/pull/1 --squash --delete-branch",
                   "gh pr merge https://github.com/jenrzzz/airing/pull/7 --squash --delete-branch" ], merges
  end

  test "major: one upgrade, never merged, never touches Dependabot" do
    @dependabot = [ { "number" => 1, "title" => "Bump puma from 6.4.0 to 6.5.0", "url" => "u" } ]
    result = upkeep(payload(scope: "major")).call
    assert_equal "review", result["status"]
    assert_includes result["review"], "scope is major: always reviewed"
    refute ran?(/\Agh pr (list|merge)/)
    assert ran?(/\Agit checkout --quiet -B upkeep\/major/)
    assert_match(/Pick \*\*one\*\* upgrade/, @commands.find { |argv, _, _| argv.first == "claude" }[2])
  end

  test "a refusal fails the mission before anything is pushed" do
    @refuse = "the app needs Ruby 4.0.6; this sandbox has 4.0.5"
    assert_match(/refused: the app needs Ruby 4.0.6/, assert_raises(Forge::Refused) { upkeep.call }.message)
    refute ran?(/\Agit push/)
  end

  test "test plans come from the repo, not the implementer" do
    @files = { "package.json" => { "scripts" => { "test" => "vitest run" } }.to_json, "package-lock.json" => "{}",
               "pyproject.toml" => "[project]\ndependencies=['pytest']\n", "uv.lock" => "", "tests/test_x.py" => "" }
    @edits = {}
    u = upkeep
    u.clone
    assert_equal [ "npm install", "npm test", "uv sync", "pytest" ], u.test_plan.map(&:last)
    assert_equal %w[npm ci], u.test_plan.first.first

    File.write(File.join(u.dir, "package.json"), { "scripts" => { "test" => "echo \"Error: no test specified\" && exit 1" } }.to_json)
    FileUtils.rm_rf(File.join(u.dir, "tests"))
    assert_empty u.test_plan
  end

  test "below 1.0 a minor holds the PR only for what the app depends on itself" do
    old = OLD_GEMS.sub("    pg (1.5.9)\n", "    pg (1.5.9)\n    hob (0.1.1)\n    reline (0.6.3)\n") +
          "\nDEPENDENCIES\n  hob (~> 0.1)\n  pg\n  rails (~> 8.1)\n"
    @files["Gemfile.lock"] = old
    @edits = { "Gemfile.lock" => old.sub("reline (0.6.3)", "reline (0.7.0)") }
    result = upkeep.call
    assert_equal "merged", result["status"], "reline is not the app's own: #{result['review'].inspect}"
    assert_equal [ [ "reline", false ] ], result["changes"].map { |c| c.values_at("name", "major") }

    @edits = { "Gemfile.lock" => old.sub("reline (0.6.3)", "reline (0.7.0)").sub("hob (0.1.1)", "hob (0.3.0)") }
    result = upkeep.call
    assert_equal "review", result["status"]
    assert_equal [ "major versions: hob 0.1.1 → 0.3.0" ], result["review"]
  end

  test "direct dependencies from each lockfile, or nil where it does not say" do
    u = upkeep
    gems = "GEM\n  specs:\n    pg (1.5.9)\n\nDEPENDENCIES\n  debug\n  pg (~> 1.1)\n  hob!\n\nBUNDLED WITH\n   2.6.9\n"
    assert_equal %w[debug pg hob], u.direct_dependencies("Gemfile.lock", gems).uniq
    lock = { "packages" => { "" => { "dependencies" => { "vite" => "^7" }, "devDependencies" => { "@types/node" => "^22" } } } }.to_json
    assert_equal %w[vite @types/node], u.direct_dependencies("web/package-lock.json", lock)
    assert_nil u.direct_dependencies("uv.lock", "")
    refute Forge::Upkeep.major?("0.27.0", "0.28.1", zero: false)
    assert Forge::Upkeep.major?("0.27.0", "1.0.0", zero: false)
  end

  test "lockfile parsers and the major rule" do
    u = upkeep
    assert_equal({ "nokogiri" => "1.18.1", "pg" => "1.5.9", "rails" => "8.1.3", "zeitwerk" => "2.7.0" }, u.gemfile_lock(OLD_GEMS))
    lock = { "packages" => { "" => { "name" => "app" }, "node_modules/vite" => { "version" => "7.1.0" },
                             "node_modules/@types/node" => { "version" => "22.1.0" },
                             "node_modules/a/node_modules/vite" => { "version" => "5.0.0" } } }.to_json
    assert_equal({ "vite" => "7.1.0", "@types/node" => "22.1.0" }, u.package_lock(lock))
    assert_equal({ "httpx" => "0.28.1" }, u.toml_lock("[[package]]\nname = \"httpx\"\nversion = \"0.28.1\"\nsource = {}\n"))

    refute Forge::Upkeep.major?("8.1.3", "8.2.0")
    assert Forge::Upkeep.major?("8.1.3", "9.0.0")
    assert Forge::Upkeep.major?("0.27.0", "0.28.1"), "below 1.0 a minor is a major"
    refute Forge::Upkeep.major?("0.27.0", "0.27.2")
    assert Forge::Upkeep.major?("2.0.0", "1.9.0"), "a downgrade across a major counts"
  end

  test "the payload is checked; Forge.build and the workspace dispatch on kind" do
    assert_match(/not an owner\/name/, assert_raises(Forge::Error) { upkeep(payload(repo: "airing")) }.message)
    assert_match(/scope "weekly"/, assert_raises(Forge::Error) { upkeep(payload(scope: "weekly")) }.message)
    assert_instance_of Forge::Upkeep, Forge.build(payload: payload, repo: @root, workdir: @workdir, log: nil)
    assert_equal "jenrzzz/airing", Forge.label!(payload)
    ws = Forge::Workspace.new(payload: payload, mission: "01JABCDEFGH12345", runner: runner, log: nil)
    assert_equal "forge-fgh12345", ws.name, "named for the mission, like a capability build"
    assert_empty @commands
  end
end
