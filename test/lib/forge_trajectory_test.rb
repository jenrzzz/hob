require "test_helper"

# Packing what Claude Code did during a build: which session files are
# taken, what is taken out of them, and what hob gets back out.
class ForgeTrajectoryTest < ActiveSupport::TestCase
  setup do
    @root = Dir.mktmpdir("forge-trajectory")
    @home = File.join(@root, "claude")
    @workdir = File.join(@root, "forge", "worktrees")
    FileUtils.mkdir_p(@workdir)
    @since = Time.now - 60
  end

  teardown { FileUtils.rm_rf(@root) }

  def session(project, path, lines, at: Time.now)
    file = File.join(@home, "projects", project, path)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, lines.map { |l| "#{l.to_json}\n" }.join)
    File.utime(at, at, file)
    file
  end

  def pack(**opts)
    Forge::Trajectory.pack(workdir: @workdir, since: @since, home: @home, secrets: [], **opts)
  end

  test "packs the sessions written under the workdir since the build began, subagents under their session" do
    here = Forge::Trajectory.slug(File.join(@workdir, "hob-calendar-read"))
    session(here, "aaaa.jsonl", [ { "type" => "user", "message" => { "content" => "Build it" } }, { "type" => "assistant" } ], at: Time.now - 5)
    session(here, "aaaa/subagents/agent-1.jsonl", [ { "type" => "user", "isSidechain" => true } ])
    session(here, "old.jsonl", [ { "type" => "user" } ], at: @since - 3600)
    session(Forge::Trajectory.slug("/somewhere/else"), "bbbb.jsonl", [ { "type" => "user" } ])

    sessions = Forge::Trajectory.unpack(pack)
    assert_equal [ "aaaa.jsonl", "aaaa/subagents/agent-1.jsonl" ], sessions.map { |s| s["path"] }
    assert_equal %w[aaaa aaaa], sessions.map { |s| s["session"] }
    assert_equal 2, sessions.first["lines"]
    assert_equal "Build it", JSON.parse(sessions.first["jsonl"].lines.first).dig("message", "content")
  end

  test "nothing written is nil, not an empty archive" do
    assert_nil pack
    session(Forge::Trajectory.slug(@workdir), "empty.jsonl", [])
    assert_nil pack
  end

  test "a secret the box can see is taken out of what is kept" do
    session(Forge::Trajectory.slug(@workdir), "aaaa.jsonl", [ { "type" => "user", "toolUseResult" => "token ghp_abcdefghijklmnop0123 printed" } ])
    text = Forge::Trajectory.unpack(pack(secrets: [ "ghp_abcdefghijklmnop0123" ])).first["jsonl"]
    assert_no_match(/ghp_/, text)
    assert_match(/token \[secret\] printed/, text)
  end

  test "a session too long to keep whole keeps its start and its end" do
    lines = Array.new(3000) { |i| "#{{ 'type' => 'assistant', 'n' => i }.to_json}\n" }
    kept = Forge::Trajectory.trim(lines.join, limit: 10_000, head: 3, tail: 5).lines
    assert_equal 9, kept.size
    assert_equal 0, JSON.parse(kept.first)["n"]
    assert_equal 2999, JSON.parse(kept.last)["n"]
    assert_match(/2992 lines left out/, JSON.parse(kept[3])["note"])
    assert_equal lines.join, Forge::Trajectory.trim(lines.join), "short enough is kept whole"
  end

  test "what is not an archive is refused by name" do
    assert_raises(Forge::Trajectory::Invalid) { Forge::Trajectory.unpack("not gzip") }
    assert_raises(Forge::Trajectory::Invalid) { Forge::Trajectory.unpack(Forge::Trajectory.gzip("[1]")) }
    assert_raises(Forge::Trajectory::Invalid) { Forge::Trajectory.unpack(Forge::Trajectory.gzip({ "format" => 9 }.to_json)) }
  end
end
