require "test_helper"

# The admin Forge pages: what the forge was handed, how each mission went,
# and what Claude Code did on it. And the door the forge hands that in by.
class AdminForgeControllerTest < ActionDispatch::IntegrationTest
  include HobWorld

  setup do
    admin_signing_in!
    @forge = Principal.create!(name: "forge", kind: "worker", max_clearance: "personal")
    @forge_token = ApiKey.issue!(principal: @forge, surface: "forge", default_clearance: "personal")
    @mission = Mission.create!(assignee: @forge, title: "Commission: a clock", realm: "personal",
                               payload: { "kind" => "forge.commission", "brief" => "Build a clock page" })
    Mission.create!(assignee: @forge, title: "Water the plants", realm: "household", payload: {})
  end
  teardown { admin_signed_out! }

  def archive
    lines = [
      { "type" => "user", "message" => { "content" => "Build a clock page" } },
      { "type" => "assistant", "message" => { "content" => [
        { "type" => "text", "text" => "Writing <b>clock.html</b> now." },
        { "type" => "tool_use", "id" => "t1", "name" => "Bash", "input" => { "command" => "git status" } }
      ] } },
      { "type" => "user", "message" => { "content" => [ { "type" => "tool_result", "tool_use_id" => "t1", "content" => "nothing to commit" } ] } },
      { "type" => "mode" }
    ]
    Forge::Trajectory.gzip({ "format" => 1, "sessions" => [ { "session" => "aaaa1111", "path" => "aaaa1111.jsonl",
                                                             "jsonl" => lines.map { |l| "#{l.to_json}\n" }.join } ] }.to_json)
  end

  def lease!
    post "/v1/missions/lease", params: { wait: 0 }, headers: { "Authorization" => "Bearer #{@forge_token}" }, as: :json
    body["lease_token"]
  end

  test "needs a signed-in person" do
    get "/admin/forge"
    assert_redirected_to "/login"
  end

  test "the holder of the lease hands in a trajectory; nobody else does" do
    token = lease!
    post "/v1/missions/#{@mission.id}/trajectory", params: { lease_token: "wrong", archive: [ archive ].pack("m0") },
                                                    headers: { "Authorization" => "Bearer #{@forge_token}" }, as: :json
    assert_response :unprocessable_entity
    assert_equal 0, MissionTrajectory.count

    post "/v1/missions/#{@mission.id}/trajectory", params: { lease_token: token, archive: [ archive ].pack("m0") },
                                                    headers: { "Authorization" => "Bearer #{@forge_token}" }, as: :json
    assert_response :ok
    assert_equal({ "mission" => @mission.id, "sessions" => 1, "lines" => 4 }, body)

    post "/v1/missions/#{@mission.id}/trajectory", params: { lease_token: token, archive: [ "junk" ].pack("m0") },
                                                    headers: { "Authorization" => "Bearer #{@forge_token}" }, as: :json
    assert_response :unprocessable_entity
    assert_equal 1, MissionTrajectory.count
  end

  test "lists forge missions and shows one with its brief and what Claude Code did" do
    Trajectories.store!(@mission, archive)
    admin_sign_in
    get "/admin/forge"
    assert_response :ok
    assert_select "#missions tbody tr", 1
    assert_select "#missions tbody", /Commission: a clock/
    assert_select "#missions tbody", { text: /Water the plants/, count: 0 }
    get "/admin/forge", params: { kind: "upkeep" }
    assert_select "#missions", /No forge missions match/

    get "/admin/forge/#{@mission.id}"
    assert_response :ok
    assert_select "#payload", /Build a clock page/
    assert_select "#steps .step", 3
    assert_select "#steps .step.text .said", /Writing <b>clock.html<\/b> now\./, "what it wrote is text, not markup"
    assert_select "#steps .step.text b", 0
    assert_select "#steps .step.tool summary", /Bash\s+git status/
    assert_select "#steps .step.tool pre", /nothing to commit/
    assert_select "#trajectory", /1 lines of bookkeeping/

    get "/admin/forge/#{@mission.id}/trajectories/#{@mission.trajectories.first.id}"
    assert_response :ok
    assert_equal 4, response.body.lines.size
    assert_match(/attachment/, response.headers["Content-Disposition"])
  end

  test "a mission with nothing kept says so, and one that is not the forge's is not there" do
    admin_sign_in
    get "/admin/forge/#{@mission.id}"
    assert_response :ok
    assert_select "#trajectory", /Nothing was kept/
    get "/admin/forge/#{Mission.find_by(title: 'Water the plants').id}"
    assert_response :not_found
  end
end
