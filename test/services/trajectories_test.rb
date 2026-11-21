require "test_helper"

# Keeping what Claude Code did on a mission, and reading a session back as
# the steps a person follows.
class TrajectoriesTest < ActiveSupport::TestCase
  include HobWorld

  setup do
    @forge = Principal.create!(name: "forge", kind: "worker", max_clearance: "personal")
    @mission = Mission.create!(assignee: @forge, title: "Commission: a clock", realm: "personal", attempts: 1,
                               payload: { "kind" => "forge.commission" })
  end

  def archive(*sessions)
    Forge::Trajectory.gzip({ "format" => 1, "sessions" => sessions }.to_json)
  end

  def jsonl(*entries)
    entries.map { |e| "#{e.to_json}\n" }.join
  end

  test "an archive's sessions are kept at the mission's realm, and a file handed over twice replaces itself" do
    text = jsonl({ "type" => "user", "message" => { "content" => "Build a clock" } })
    rows = Trajectories.store!(@mission, archive({ "session" => "aaaa", "path" => "aaaa.jsonl", "jsonl" => text },
                                                 { "session" => "aaaa", "path" => "aaaa/subagents/agent-1.jsonl", "jsonl" => text }))
    assert_equal 2, rows.size
    row = @mission.trajectories.in_order.first
    assert_equal [ "personal", "aaaa", 1, 1, text.bytesize ], [ row.realm, row.session, row.attempt, row.lines, row.bytes ]
    assert_equal text, row.jsonl
    assert_not row.side?
    assert @mission.trajectories.in_order.last.side?

    longer = text * 3
    Trajectories.store!(@mission, archive({ "session" => "aaaa", "path" => "aaaa.jsonl", "jsonl" => longer }))
    assert_equal 2, @mission.trajectories.count
    assert_equal 3, @mission.trajectories.find_by(path: "aaaa.jsonl").lines

    Clearance.with("household") { assert_equal 0, MissionTrajectory.count }
  end

  test "what is not an archive, or holds nothing, is refused" do
    assert_raises(Gateway::Invalid) { Trajectories.store!(@mission, "") }
    assert_raises(Gateway::Invalid) { Trajectories.store!(@mission, "junk") }
    assert_raises(Gateway::Invalid) { Trajectories.store!(@mission, archive) }
    assert_equal 0, MissionTrajectory.count
  end

  test "a session reads as steps, each tool call carrying what came back" do
    text = jsonl(
      { "type" => "mode", "mode" => "normal" },
      { "type" => "user", "timestamp" => "2026-11-21T21:39:10Z", "message" => { "content" => "Build a clock" } },
      { "type" => "assistant", "message" => { "content" => [
        { "type" => "thinking", "thinking" => "A page, then." },
        { "type" => "text", "text" => "I'll write the page." },
        { "type" => "tool_use", "id" => "t1", "name" => "Bash", "input" => { "command" => "ls\n-la", "description" => "List" } },
        { "type" => "tool_use", "id" => "t2", "name" => "Write", "input" => { "file_path" => "clock.html", "content" => "<p>" } }
      ] } },
      { "type" => "user", "message" => { "content" => [
        { "type" => "tool_result", "tool_use_id" => "t1", "content" => "README.md" },
        { "type" => "tool_result", "tool_use_id" => "t2", "is_error" => true, "content" => [ { "type" => "text", "text" => "denied" }, { "type" => "image" } ] }
      ] } },
      { "type" => "system", "subtype" => "compact_boundary", "content" => "Conversation compacted" },
      { "type" => "forge-note", "note" => "12 lines left out here" }
    ) + "not json\n"
    steps, skipped = Trajectories.steps(text)
    assert_equal %i[prompt thinking text tool tool note note], steps.map(&:kind)
    assert_equal 2, skipped, "the mode line and the one that is not JSON"
    bash, write = steps.select { |s| s.kind == :tool }
    assert_equal [ "Bash", "README.md", false ], [ bash.name, bash.result, bash.failed ]
    assert_equal "ls -la", Trajectories.headline(bash)
    assert_equal [ "denied\n[image]", true ], [ write.result, write.failed ]
    assert_equal "clock.html", Trajectories.headline(write)
    assert_equal [ "abc", 3 ], Trajectories.clip("abcdef", 3)
  end
end
