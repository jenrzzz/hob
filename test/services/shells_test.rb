require "test_helper"

# Shells (SHELL.md): one command at a time on a machine, over the in-memory
# Fake. RLS decides which hosts exist for a call, and a host kept for one
# agent is that agent's alone; arguments are checked before anything leaves
# hob; what comes back is kept within limits.
class ShellsTest < ActiveSupport::TestCase
  Fake = Shells::Backends::Fake

  setup do
    @box = shell_host("box", about: "A test machine")
    @machine = Fake.machine("box")
  end

  teardown { Fake.reset! }

  test "exec: the only visible host runs the command and answers with its exit and what it printed" do
    @machine.on(/\Auname/) { { "stdout" => "Linux 6.8\n", "stderr" => "warn\n", "exit" => 3 } }
    result = Shells.exec(command: "uname -sr")
    assert_equal "box", result["host"]
    assert_equal 3, result["exit"]
    assert_equal "Linux 6.8\n", result["stdout"]
    assert_equal "warn\n", result["stderr"]
    assert_kind_of Float, result["seconds"]
    refute result.key?("truncated")
    refute result.key?("timed_out")
    assert_equal [ [ :exec, "uname -sr", { timeout: Shells::DEFAULT_TIMEOUT } ] ], @machine.calls
  end

  test "exec: cwd is quoted in front of the command, stdin and timeout go along" do
    Shells.exec(command: "ls | wc -l", cwd: "~/my site", stdin: "in", timeout: 5)
    assert_equal [ :exec, "cd -- my\\ site && ls | wc -l", { stdin: "in", timeout: 5 } ], @machine.calls.last
    Shells.exec(command: "ls", cwd: "/var/www")
    assert_equal "cd -- /var/www && ls", @machine.calls.last[1]
  end

  test "exec: arguments are checked before the machine hears anything" do
    assert_raises(Shells::Invalid) { Shells.exec(command: " ") }
    assert_raises(Shells::Invalid) { Shells.exec(command: "x" * (Shells::MAX_COMMAND + 1)) }
    assert_raises(Shells::Invalid) { Shells.exec(command: "ls", stdin: "x" * (Shells::MAX_STDIN + 1)) }
    assert_raises(Shells::Invalid) { Shells.exec(command: "ls", timeout: Shells::MAX_TIMEOUT + 1) }
    assert_raises(Shells::Invalid) { Shells.exec(command: "ls", timeout: "soon") }
    assert_raises(Shells::Invalid) { Shells.exec(command: "ls", cwd: "a\nb") }
    assert_raises(Shells::Invalid) { Shells.exec(command: "ls", cwd: "-rf") }
    assert_raises(Shells::Invalid) { Shells.exec(command: "ls", cwd: "~root") }
    assert_empty @machine.calls
  end

  test "exec: long output keeps its start and its end, and a command past its timeout is left with a note" do
    @machine.on(/big/) { { "stdout" => "A" * 30_000 + "B" * 30_000 } }
    result = Shells.exec(command: "big")
    assert_equal true, result["truncated"]
    assert_match(/\AA+\n\[\.\.\. 28000 bytes left out \.\.\.\]\nB+\z/, result["stdout"])
    assert_operator result["stdout"].bytesize, :<, Shells::MAX_OUTPUT + 100

    @machine.on(/sleep/) { { "stdout" => "started\n", "timed_out" => true } }
    result = Shells.exec(command: "sleep 900", timeout: 2)
    assert_nil result["exit"]
    assert_equal true, result["timed_out"]
    assert_equal "started\n", result["stdout"]
    assert_match(/within 2 seconds.*may still be running on box/, result["note"])
  end

  test "exec: output that is not UTF-8 is scrubbed, never raised on" do
    @machine.on(/bin/) { { "stdout" => "ok \xFF\xFE end".b } }
    result = Shells.exec(command: "bin")
    assert result["stdout"].valid_encoding?
    assert_equal "ok �� end", result["stdout"]
    assert result.to_json
  end

  test "write then read: a file round-trips, appends, and reads in slices" do
    written = Shells.write(path: "~/site/index.html", content: "<h1>hi</h1>\n", mode: "644")
    assert_equal({ "host" => "box", "path" => "site/index.html", "bytes" => 12, "appended" => false }, written)
    assert_equal [ :write, "site/index.html", { append: false, mode: "644" } ], @machine.calls.last
    Shells.write(path: "site/index.html", content: "more\n", append: true)

    read = Shells.read(path: "site/index.html")
    assert_equal "<h1>hi</h1>\nmore\n", read["content"]
    assert_equal 17, read["bytes"]
    assert_equal false, read["truncated"]

    slice = Shells.read(path: "site/index.html", offset: 4, max_bytes: 2)
    assert_equal "hi", slice["content"]
    assert_equal 4, slice["offset"]
    assert_equal true, slice["truncated"]
  end

  test "read and write: a missing file, a binary file, and bad arguments" do
    assert_raises(Shells::NotFound) { Shells.read(path: "nope.txt") }
    @machine.files["db.sqlite3"] = "SQLite format 3\0\0\0".b
    assert_match(/is not text \(18 bytes\)/, assert_raises(Shells::Invalid) { Shells.read(path: "db.sqlite3") }.message)
    assert_raises(Shells::Invalid) { Shells.read(path: "a", max_bytes: Shells::MAX_READ + 1) }
    assert_raises(Shells::Invalid) { Shells.read(path: "") }
    assert_raises(Shells::Invalid) { Shells.write(path: "a", content: "x" * (Shells::MAX_CONTENT + 1)) }
    assert_raises(Shells::Invalid) { Shells.write(path: "a", content: "x", mode: "rwx") }
    assert_raises(Shells::Invalid) { Shells.write(path: "a", content: nil) }
    assert_equal 0, Shells.write(path: "empty", content: "")["bytes"]
  end

  test "hosts: named when there are two, unknown and disabled ones are not found" do
    shell_host("other")
    assert_match(/name the host: one of box, other/, assert_raises(Shells::Invalid) { Shells.exec(command: "ls") }.message)
    assert_equal "other", Shells.exec(command: "ls", host: "other")["host"]
    assert_match(/no host named "nope" \(visible: box, other\)/, assert_raises(Shells::NotFound) { Shells.exec(command: "ls", host: "nope") }.message)
    ShellHost.update_all(enabled: false)
    assert_raises(Shells::NotFound) { Shells.exec(command: "ls", host: "box") }
  end

  test "realm: a host above the caller's clearance does not exist for it" do
    shell_host("private", realm: "personal")
    muse, = agent("muse", clearance: "household")
    as(muse, realm: "household") do
      assert_equal %w[box], Shells.hosts.map(&:name)
      assert_raises(Shells::NotFound) { Shells.exec(command: "ls", host: "private") }
    end
  end

  test "a host kept for one agent is hers alone, she reaches no other, and people reach all" do
    meluzina, = agent("meluzina", clearance: "personal")
    muse, = agent("muse", clearance: "personal")
    hers = shell_host("meluzina-box", agent: meluzina)

    as(meluzina, realm: "personal") do
      assert_equal %w[meluzina-box], Shells.hosts.map(&:name)
      assert_equal "meluzina-box", Shells.exec(command: "ls")["host"]
      assert_raises(Shells::NotFound) { Shells.exec(command: "ls", host: "box") }
    end
    as(muse, realm: "personal") do
      assert_equal %w[box], Shells.hosts.map(&:name)
      assert_raises(Shells::NotFound) { Shells.exec(command: "ls", host: "meluzina-box") }
    end
    assert_equal %w[box meluzina-box], Shells.hosts.map(&:name), "a person"

    hers.update!(enabled: false)
    as(meluzina, realm: "personal") do
      assert_empty Shells.hosts, "her own is off: she finds nothing, not everyone else's"
    end
  end

  test "a machine that is away, or refuses, raises what the adapter raised" do
    Fake.fail!("box", Shells::Unavailable.new("box did not answer"))
    assert_raises(Shells::Unavailable) { Shells.exec(command: "ls") }
    assert_raises(Shells::Unavailable) { Shells.read(path: "a") }
    assert_raises(Shells::Unavailable) { Shells.write(path: "a", content: "x") }
  end
end
