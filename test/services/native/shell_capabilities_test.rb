require "test_helper"

# shell.* (SHELL.md): how an outside agent runs commands on a machine.
# Realm and whose the host is are the fences; each command is a request row
# with its arguments and what the machine said.
class ShellCapabilitiesTest < ActiveSupport::TestCase
  Fake = Shells::Backends::Fake
  NAMES = %w[shell.hosts shell.exec shell.read shell.write].freeze

  setup do
    native_capabilities!
    @meluzina, = agent("meluzina", clearance: "personal")
    policy!(@meluzina, "shell.*", "allow")
    @box = shell_host("meluzina-box", agent: @meluzina, about: "Her own server; serves meluzina.example to the internet")
    @machine = Fake.machine("meluzina-box")
  end

  teardown { Fake.reset! }

  def submit(capability, arguments = {}, agent: @meluzina, realm: "personal", **options)
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments, **options) }
  end

  def completed(capability, arguments = {}, **options)
    request = submit(capability, arguments, **options)
    assert_equal "completed", request.status, request.error.to_s
    request
  end

  def failed(capability, arguments = {}, **options)
    request = submit(capability, arguments, **options)
    assert_equal "failed", request.status
    request.error
  end

  test "sync! registers the four capabilities: two reads, two acts, at household, with closed schemas" do
    caps = Capability.where(name: NAMES).index_by(&:name)
    assert_equal NAMES.sort, caps.keys.sort
    assert_equal %w[shell.hosts shell.read], caps.values.select { |c| c.kind == "read" }.map(&:name).sort
    caps.each_value do |cap|
      assert cap.native?
      assert_equal "household", cap.realm
      assert_equal false, cap.input_schema["additionalProperties"], cap.name
      assert cap.description.length > 80, "#{cap.name}: agents read these"
    end
    assert_equal %w[command], caps["shell.exec"].input_schema["required"]
    assert_equal %w[path content], caps["shell.write"].input_schema["required"]
  end

  test "hosts, write, exec, read: her own machine, with the notice, and the row keeps the command and its answer" do
    hosts = completed("shell.hosts").result
    assert_equal [ { "name" => "meluzina-box", "login" => "hob@meluzina-box.test",
                     "about" => "Her own server; serves meluzina.example to the internet", "yours" => true } ], hosts["hosts"]
    assert_equal Shells::NOTICE, hosts["notice"]

    written = completed("shell.write", { "path" => "~/site/index.html", "content" => "<h1>hi</h1>" }).result
    assert_equal "site/index.html", written["path"]
    assert_equal 11, written["bytes"]

    @machine.on(/caddy/) { { "stdout" => "active\n" } }
    ran = completed("shell.exec", { "command" => "systemctl is-active caddy", "timeout" => 10 })
    assert_equal 0, ran.result["exit"]
    assert_equal "active\n", ran.result["stdout"]
    assert_equal Shells::NOTICE, ran.result["notice"]
    stored = SentinelRequest.find(ran.id)
    assert_equal({ "command" => "systemctl is-active caddy", "timeout" => 10 }, stored.arguments)
    assert_equal "active\n", stored.result["stdout"]

    read = completed("shell.read", { "path" => "site/index.html" }).result
    assert_equal "<h1>hi</h1>", read["content"]
    assert_equal false, read["truncated"]
  end

  test "a command that fails on the machine is a completed request with its exit; a refused one fails with the reason" do
    @machine.on(/false/) { { "exit" => 1, "stderr" => "nope\n" } }
    ran = completed("shell.exec", { "command" => "false" }).result
    assert_equal 1, ran["exit"]
    assert_equal "nope\n", ran["stderr"]

    assert_match(/command/, failed("shell.exec", {}))
    assert_match(/timeout must be a whole number/, failed("shell.exec", { "command" => "ls", "timeout" => 9999 }))
    assert_match(/No such file/, failed("shell.read", { "path" => "nope" }))
    assert_match(/content is required/, failed("shell.write", { "path" => "a" }))
    Fake.fail!("meluzina-box", Shells::Unavailable.new("meluzina-box did not answer at 100.64.0.9:22"))
    assert_match(/Unavailable: meluzina-box did not answer/, failed("shell.exec", { "command" => "ls" }))
  end

  test "her machine is hers: another agent with shell.* cannot name it, and she cannot name another's" do
    shell_host("house-box")
    muse, = agent("muse", clearance: "personal")
    policy!(muse, "shell.*", "allow")
    assert_equal %w[house-box], completed("shell.hosts", {}, agent: muse).result["hosts"].map { |h| h["name"] }
    assert_match(/no host named "meluzina-box"/, failed("shell.exec", { "command" => "ls", "host" => "meluzina-box" }, agent: muse))
    assert_match(/no host named "house-box"/, failed("shell.exec", { "command" => "ls", "host" => "house-box" }))
    assert_empty Fake.machine("house-box").calls
    assert_empty @machine.calls
  end

  test "an agent without a grant is not served, and a host above the request's realm is out of sight" do
    stranger, = agent("stranger", clearance: "personal")
    refute_equal "completed", submit("shell.exec", { "command" => "ls" }, agent: stranger).status
    assert_equal 0, @machine.calls.size

    @box.update!(realm: "personal")
    assert_match(/no host is visible/, failed("shell.exec", { "command" => "ls" }, realm: "household"))
  end
end
