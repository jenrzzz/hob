require "test_helper"

# code.* (CODE.md): an agent hands building work to Claude Code. A
# commission is a mission for the forge, in a repo that is the agent's own;
# the agent starts one and reads how it went later, in status or in a beat.
class CodeCapabilitiesTest < ActiveSupport::TestCase
  BRIEF = "A guestbook page: a form with a name and a message, stored in sqlite, newest first. Runs with ruby app.rb on port 8080.".freeze

  setup do
    native_capabilities!
    @forge, = forge!
    @meluzina, = agent("meluzina", clearance: "personal")
    policy!(@meluzina, "code.*", "allow")
    @repo = code_repo("meluzina-box", agent: @meluzina, repo: "jenrzzz/meluzina-box", about: "Cloned at ~/workshop on your machine")
  end

  def submit(capability, arguments = {}, agent: @meluzina, realm: "personal")
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments) }
  end

  def completed(capability, arguments = {}, **options)
    request = submit(capability, arguments, **options)
    assert_equal "completed", request.status, request.error.to_s
    request.result
  end

  def failed(capability, arguments = {}, **options)
    request = submit(capability, arguments, **options)
    assert_equal "failed", request.status
    request.error
  end

  def start(**over)
    completed("code.start", { "title" => "A guestbook", "brief" => BRIEF }.merge(over.transform_keys(&:to_s)))
  end

  test "sync! registers the two capabilities, at household, with closed schemas" do
    caps = Capability.where(name: %w[code.start code.status]).index_by(&:name)
    assert_equal "act", caps["code.start"].kind
    assert_equal "read", caps["code.status"].kind
    caps.each_value do |cap|
      assert_equal "household", cap.realm
      assert_equal false, cap.input_schema["additionalProperties"]
    end
    assert_equal %w[title brief], caps["code.start"].input_schema["required"]
  end

  test "start queues a forge.commission mission for the forge, in her repo, in her name" do
    result = start(branch: "guestbook")
    assert_equal "waiting", result["state"]
    assert_equal "A guestbook", result["title"]
    assert_equal "meluzina-box", result["repo"]
    assert_equal "guestbook", result["branch"]
    assert_equal Sentinel::Native::CodeHandler::NOTICE, result["notice"]

    mission = Clearance.with("personal") { Mission.find(result["id"]) }
    assert_equal @forge, mission.assignee
    assert_equal @meluzina, mission.created_by
    assert_equal "personal", mission.realm
    assert_equal "Commission: A guestbook", mission.title
    assert_equal({ "kind" => "forge.commission", "repo" => "jenrzzz/meluzina-box", "branch" => "guestbook", "title" => "A guestbook",
                   "brief" => BRIEF, "for" => "meluzina", "code_repo" => "meluzina-box" }, mission.payload)
    assert_nil mission.sentinel_request_id, "the request that started it is done; the mission's end does not rewrite it"
  end

  test "status: in brief with her repos, and one in full once the forge has finished it" do
    id = start["id"]
    listed = completed("code.status")
    assert_equal [ id ], listed["commissions"].map { |c| c["id"] }
    assert_equal [ { "name" => "meluzina-box", "repo" => "jenrzzz/meluzina-box", "about" => "Cloned at ~/workshop on your machine" } ], listed["repos"]

    Clearance.with("intimate") do
      Mission.find(id).complete!({ "repo" => "jenrzzz/meluzina-box", "branch" => "main", "status" => "pushed",
                                   "commits" => [ "abc1234 Add the guestbook" ], "commit_count" => 1, "files" => 3,
                                   "summary" => "Made app.rb and a schema.\nRun it with ruby app.rb.", "cost" => 0.4,
                                   "url" => "https://github.com/jenrzzz/meluzina-box/commits/main" })
    end
    brief = completed("code.status")["commissions"].first
    assert_equal "done", brief["state"]
    assert_equal "pushed", brief["outcome"]
    assert_equal 1, brief["commits"]
    assert_equal "Made app.rb and a schema.", brief["said"]
    refute brief.key?("brief")

    full = completed("code.status", { "id" => id })["commission"]
    assert_equal [ "abc1234 Add the guestbook" ], full["commits"]
    assert_equal "Made app.rb and a schema.\nRun it with ruby app.rb.", full["said"]
    assert_equal BRIEF, full["brief"]
    assert full["finished_at"]
  end

  test "a failed commission says why" do
    id = start["id"]
    Clearance.with("intimate") { Mission.find(id).fail!("Refused: this sandbox's GitHub token can push to jenrzzz/hob") }
    one = completed("code.status", { "id" => id })["commission"]
    assert_equal "failed", one["state"]
    assert_match(/token can push to jenrzzz\/hob/, one["error"])
  end

  test "what is asked is checked, and no more than two are under way at once" do
    assert_match(/brief is the whole request/, failed("code.start", { "title" => "A page", "brief" => "make a page" }))
    assert_match(/title is a few words/, failed("code.start", { "title" => "x", "brief" => BRIEF }))
    assert_match(/branch is a git branch name/, failed("code.start", { "title" => "A page", "brief" => BRIEF, "branch" => "../x" }))
    assert_match(/no repo named "nope" \(yours: meluzina-box\)/, failed("code.start", { "title" => "A page", "brief" => BRIEF, "repo" => "nope" }))
    start
    start(title: "A second thing")
    assert_match(/2 commissions under way already/, failed("code.start", { "title" => "A third thing", "brief" => BRIEF }))
    assert_equal 2, Clearance.with("personal") { Mission.count }
  end

  test "the repo and the commissions are hers: another agent with code.* has neither" do
    id = start["id"]
    muse, = agent("muse", clearance: "personal")
    policy!(muse, "code.*", "allow")
    assert_match(/no repo is set up for you/, failed("code.start", { "title" => "A page", "brief" => BRIEF }, agent: muse))
    listed = completed("code.status", {}, agent: muse)
    assert_empty listed["commissions"]
    assert_empty listed["repos"]
    assert_match(/no commission/, failed("code.status", { "id" => id }, agent: muse))
  end

  test "with no forge, or a repo out of sight, there is nothing to hand it to" do
    @forge.update!(name: "retired")
    assert_match(/no forge to hand work to/, failed("code.start", { "title" => "A page", "brief" => BRIEF }))
    assert_match(/no repo is set up for you/, failed("code.start", { "title" => "A page", "brief" => BRIEF }, realm: "household"))
    assert_not CodeRepo.new(name: "x", repo: "not a repo", realm: "personal", principal: @principal, agent: @meluzina).valid?
    assert_not CodeRepo.new(name: "x", repo: "a/b", realm: "personal", principal: @principal, agent: @principal).valid?
  end
end
