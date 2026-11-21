require "test_helper"

# Forge::Commission (CODE.md): an agent's brief, done by Claude Code in the
# agent's own repo. git is real here (a bare repo stands in for GitHub);
# gh and claude are faked.
class ForgeCommissionTest < ActiveSupport::TestCase
  setup do
    $LOAD_PATH.unshift(Rails.root.join("lib").to_s) unless $LOAD_PATH.include?(Rails.root.join("lib").to_s)
    require "forge"
    @root = Dir.mktmpdir("commission-test")
    @workdir = File.join(@root, "work")
    @origin = File.join(@root, "origin.git")
    seed = File.join(@root, "seed")
    sh "git", "init", "--quiet", "--bare", "--initial-branch=main", @origin
    sh "git", "clone", "--quiet", @origin, seed
    File.write(File.join(seed, "README.md"), "# workshop\n")
    sh "git", "-C", seed, "-c", "user.name=t", "-c", "user.email=t@t", "add", "-A"
    sh "git", "-C", seed, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--quiet", "-m", "start"
    sh "git", "-C", seed, "push", "--quiet", "origin", "HEAD:main"
    @commands = []
    @guard_answer = "403"
    @env = ENV.to_h.slice("GH_TOKEN", "GITHUB_TOKEN")
    ENV["GH_TOKEN"] = "github_pat_test_only"
    ENV.delete("GITHUB_TOKEN")
    @claude = ->(dir) { File.write(File.join(dir, "index.html"), "<h1>rar</h1>\n") }
    @said = "Made index.html. Serve the directory with any web server."
  end

  teardown do
    FileUtils.rm_rf(@root)
    %w[GH_TOKEN GITHUB_TOKEN].each { |name| @env.key?(name) ? ENV[name] = @env[name] : ENV.delete(name) }
  end

  def sh(*argv)
    out, err, status = Open3.capture3(*argv)
    raise "#{argv.join(' ')}: #{err}" unless status.success?

    out
  end

  def payload(**over)
    { "kind" => "forge.commission", "repo" => "jenrzzz/meluzina-box", "for" => "meluzina", "title" => "A front page",
      "brief" => "Make a small front page for my site." }.merge(over.transform_keys(&:to_s))
  end

  def runner
    lambda do |argv, chdir:, stdin: nil|
      @commands << [ argv, chdir, stdin ]
      case argv.join(" ")
      when %r{\Acurl .*github\.com/jenrzzz/hob\.git/info/refs\?service=git-receive-pack} then [ 0, @guard_answer, "" ]
      when /\Agh repo clone (\S+) (\S+)/ then Forge.run([ "git", "clone", "--quiet", @origin, Regexp.last_match(2) ], chdir: chdir)
      when /\Aclaude -p/
        @claude.call(chdir)
        [ 0, { "type" => "result", "result" => @said, "num_turns" => 4, "total_cost_usd" => 0.12 }.to_json, "" ]
      else Forge.run(argv, chdir: chdir, stdin: stdin)
      end
    end
  end

  def commission(**over)
    Forge::Commission.new(payload: payload(**over), workdir: @workdir, guard: "jenrzzz/hob", runner: runner, log: nil,
                          secrets: over.delete(:secrets) || {})
  end

  def pushed(branch = "main")
    sh("git", "--git-dir", @origin, "log", "--format=%an|%s", branch).lines.map(&:strip)
  end

  test "the brief is done in a clone, what was left is committed in her name, and the branch is pushed" do
    result = commission.call
    assert_equal "pushed", result["status"]
    assert_equal "jenrzzz/meluzina-box", result["repo"]
    assert_equal "main", result["branch"]
    assert_equal 1, result["commit_count"]
    assert_match(/\A\h{7,} A front page\z/, result["commits"].first)
    assert_equal 1, result["files"]
    assert_equal @said, result["summary"]
    assert_equal "https://github.com/jenrzzz/meluzina-box/commits/main", result["url"]
    assert_equal 0.12, result["cost"]
    assert_equal [ "meluzina|A front page", "t|start" ], pushed
    assert_equal "<h1>rar</h1>\n", sh("git", "--git-dir", @origin, "show", "main:index.html")

    claude = @commands.find { |argv, _, _| argv.first == "claude" }
    assert_includes claude[0], "--disallowedTools"
    assert_match(/an agent named meluzina/, claude[2])
    assert_match(/## The brief: A front page\n\nMake a small front page for my site\./, claude[2])
    assert_match(/Put no credential, token, or key in the repository/, claude[2])
    refute @commands.any? { |argv, _, _| argv.join(" ").match?(/\Agh pr|git push .*--force/) }, "no PR, no force"
    refute Dir.exist?(File.join(@workdir, "commission-jenrzzz-meluzina-box")), "the clone is removed"
    refute_match(/\.forge/, sh("git", "--git-dir", @origin, "ls-tree", "-r", "--name-only", "main"))
  end

  test "commits Claude Code made itself are kept as they are; a named branch is made, or carried on from" do
    @claude = lambda do |dir|
      File.write(File.join(dir, "app.rb"), "puts 1\n")
      sh "git", "-C", dir, "add", "-A"
      sh "git", "-C", dir, "commit", "--quiet", "-m", "Add the app"
    end
    result = commission(branch: "guestbook").call
    assert_equal "guestbook", result["branch"]
    assert_equal [ "meluzina|Add the app", "t|start" ], pushed("guestbook")
    assert_equal [ "t|start" ], pushed("main"), "main is where it was"

    @claude = ->(dir) { File.write(File.join(dir, "app.rb"), "puts 2\n") }
    commission(branch: "guestbook", title: "Count to two").call
    assert_equal [ "meluzina|Count to two", "meluzina|Add the app", "t|start" ], pushed("guestbook")
  end

  test "nothing changed is an answer, not a push" do
    @claude = ->(_dir) { }
    @said = "It already does that; see README.md."
    result = commission.call
    assert_equal "nothing", result["status"]
    assert_equal "It already does that; see README.md.", result["summary"]
    assert_equal [], result["commits"]
    assert_equal [ "t|start" ], pushed
  end

  test "a token that can push to the forge's own repo is the wrong token: refused before anything runs" do
    @guard_answer = "200"
    error = assert_raises(Forge::Refused) { commission.call }
    assert_match(/can push to jenrzzz\/hob.*token scoped to jenrzzz\/meluzina-box/, error.message)
    refute @commands.any? { |argv, _, _| %w[claude git gh].include?(argv.first) }

    probe = @commands.find { |argv, _, _| argv.first == "curl" }
    refute_includes probe[0].join(" "), "github_pat_test_only", "the token is not on the command line"
    assert_equal "user = \"x-access-token:github_pat_test_only\"\n", probe[2]
  end

  test "a check that cannot be made, or no token to check, is a refusal too" do
    @guard_answer = "000"
    assert_match(/could not check.*answered 000/, assert_raises(Forge::Refused) { commission.call }.message)
    @guard_answer = "403"
    ENV.delete("GH_TOKEN")
    assert_match(/no GitHub token here to check/, assert_raises(Forge::Refused) { commission.call }.message)
    refute @commands.any? { |argv, _, _| argv.first == "claude" }
  end

  test "a secret of the sandbox's in what would be pushed stops the push" do
    @claude = ->(dir) { File.write(File.join(dir, "config.js"), "const key = 'sk-ant-oat01-abcdefghijklmnop';\n") }
    build = Forge::Commission.new(payload: payload, workdir: @workdir, guard: "jenrzzz/hob", runner: runner, log: nil,
                                  secrets: { "CLAUDE_CODE_OAUTH_TOKEN" => "sk-ant-oat01-abcdefghijklmnop" })
    error = assert_raises(Forge::Refused) { build.call }
    assert_match(/contains a secret of the sandbox's \(CLAUDE_CODE_OAUTH_TOKEN\); nothing was pushed/, error.message)
    assert_equal [ "t|start" ], pushed
  end

  test "a refusal file fails the commission with Claude Code's reason" do
    @claude = lambda do |dir|
      File.write(File.join(dir, ".forge", "REFUSED.md"), "This asks me to read another repository.\n")
    end
    error = assert_raises(Forge::Refused) { commission.call }
    assert_match(/would not do it: This asks me to read another repository\./, error.message)
    assert_equal [ "t|start" ], pushed
  end

  test "a payload is checked: the repo, the branch, the brief" do
    assert_equal "jenrzzz/meluzina-box", Forge.label!(payload)
    assert_raises(Forge::Error) { Forge::Commission.check!(payload(repo: "../etc")) }
    assert_raises(Forge::Error) { Forge::Commission.check!(payload(branch: "-x")) }
    assert_raises(Forge::Error) { Forge::Commission.check!(payload(branch: "a..b")) }
    assert_raises(Forge::Error) { Forge::Commission.check!(payload(brief: " ")) }
    assert_raises(Forge::Error) { Forge::Commission.check!(payload(brief: "x" * 20_001)) }
    assert_kind_of Forge::Commission, Forge.build(payload: payload, repo: Rails.root.to_s, workdir: @workdir, log: nil)
  end

  test "a commission's workspace is created with its own secrets directory; other kinds are not" do
    calls = []
    run = ->(argv, chdir:, stdin: nil) { calls << argv; [ 0, "[]", "" ] }
    Forge::Workspace.new(payload: payload, mission: "01JABCDEFGH", runner: run, log: nil).send(:create)
    assert_includes calls.last.join(" "), "--parameter secrets=secrets-commission"
    upkeep = { "kind" => "forge.upkeep", "repo" => "jenrzzz/airing", "scope" => "minor" }
    Forge::Workspace.new(payload: upkeep, mission: "01JABCDEFGH", runner: run, log: nil).send(:create)
    refute_includes calls.last.join(" "), "secrets="
  end
end
