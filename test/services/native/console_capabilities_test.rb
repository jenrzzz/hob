require "test_helper"

# console.* (KVM.md): how an outside agent uses a KVM. Every action is
# allowed for now; realm and session ownership are the fences. Each step is
# a request row with its arguments and the frame's size, never the image:
# the image goes to the caller, in memory, and nowhere else.
class ConsoleCapabilitiesTest < ActiveSupport::TestCase
  Fake = Consoles::Backends::Fake
  NAMES = %w[console.open console.act console.screen console.close console.sessions].freeze

  setup do
    native_capabilities!
    @muse, = agent("muse", clearance: "personal")
    policy!(@muse, "console.*", "allow")
    @mac = kvm("jenner-mac", machine: "Jenner's MacBook")
  end

  teardown { Fake.reset! }

  def submit(capability, arguments = {}, agent: @muse, realm: "personal", **options)
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

  def open!
    completed("console.open", { "goal" => "turn off Focus mode on Jenner's Mac" })
  end

  test "sync! registers the five capabilities: two reads, three acts, at household, with closed schemas" do
    caps = Capability.where(name: NAMES).index_by(&:name)
    assert_equal NAMES.sort, caps.keys.sort
    assert_equal %w[console.screen console.sessions], caps.values.select { |c| c.kind == "read" }.map(&:name).sort
    caps.each_value do |cap|
      assert cap.native?
      assert_equal "household", cap.realm
      assert_equal false, cap.input_schema["additionalProperties"], cap.name
      assert cap.description.length > 80, "#{cap.name}: agents read these"
    end
    assert_equal %w[goal], caps["console.open"].input_schema["required"]
    assert_equal Consoles::ACTIONS.keys, caps["console.act"].input_schema.dig("properties", "action", "enum")
    act_args = caps["console.act"].input_schema["properties"].keys
    Consoles::ACTIONS.values.flatten.uniq.each { |arg| assert_includes act_args, arg, "every action argument is in the schema" }
  end

  test "open, act, screen, sessions, close: the image goes back in memory; the rows keep its size and not the picture" do
    mission = Mission.create!(assignee: @muse, created_by: @principal, title: "Focus", realm: "personal")
    opened = completed("console.open", { "goal" => "turn off Focus mode on Jenner's Mac" }, on_mission: mission.id)
    session = opened.result["session"]
    assert_equal "jenner-mac", session["console"]
    assert_equal({ "width" => 1280, "height" => 720 }, opened.result["screen"])
    assert_equal Consoles::NOTICE, opened.result["notice"]
    assert_equal 1, opened.images.size
    assert_equal "image/png", opened.images.first["mimeType"]
    assert_match(/PNG fake frame 1/, Base64.decode64(opened.images.first["data"]))
    refute opened.result.key?(Sentinel::Native::IMAGES)

    row = ConsoleSession.find(session["id"])
    assert_equal @muse, row.principal
    assert_equal opened.id, row.sentinel_request_id
    assert_equal mission.id, row.on_mission_id

    step = completed("console.act", { "session" => session["id"], "action" => "left_click", "x" => 10, "y" => 20 })
    assert_equal 1, step.result["session"]["steps"]
    assert_equal 1, step.images.size
    stored = SentinelRequest.find(step.id)
    assert_equal({ "session" => session["id"], "action" => "left_click", "x" => 10, "y" => 20 }, stored.arguments)
    assert_equal({ "width" => 1280, "height" => 720 }, stored.result["screen"])
    refute_match(/PNG|"data"/, stored.result.to_json, "the frame is never stored")
    assert_equal [], stored.images

    screen = completed("console.screen", { "session" => session["id"], "scale" => 1920 })
    assert_equal 1920, screen.result["screen"]["width"]
    assert_equal 1, screen.images.size

    listed = completed("console.sessions").result
    assert_equal [ session["id"] ], listed["sessions"].map { |s| s["id"] }
    assert_equal [ { "name" => "jenner-mac", "machine" => "Jenner's MacBook" } ], listed["consoles"]

    closed = completed("console.close", { "session" => session["id"] }).result
    assert_equal "closed", closed["session"]["status"]
    assert_equal [], completed("console.sessions").result["sessions"]
  end

  test "a refused action fails the request with the reason" do
    session = open!.result["session"]
    assert_match(/action is one of/, failed("console.act", { "session" => session["id"], "action" => "reboot" }))
    assert_match(/does not take/, failed("console.act", { "session" => session["id"], "action" => "screenshot", "x" => 1 }))
    assert_match(/goal/, failed("console.open", {}))
  end

  test "a session is the agent's alone, and a household agent cannot see a personal console" do
    session = open!.result["session"]
    other, = agent("other", clearance: "personal")
    policy!(other, "console.*", "allow")
    assert_match(/no session/, failed("console.act", { "session" => session["id"], "action" => "screenshot" }, agent: other))
    assert_match(/no session/, failed("console.close", { "session" => session["id"] }, agent: other))
    assert_match(/in use by another session/, failed("console.open", { "goal" => "open the settings on the Mac" }, agent: other))

    tessa_muse, = agent("tessa-muse", clearance: "household")
    policy!(tessa_muse, "console.*", "allow")
    assert_match(/no console is visible/, failed("console.open", { "goal" => "open the settings on the Mac" }, agent: tessa_muse, realm: "household"))
    assert_equal [], completed("console.sessions", {}, agent: tessa_muse, realm: "household").result["consoles"]
  end

  test "a taken-over session answers gone, and the row says lost" do
    session = open!.result["session"]
    Fake.device("jenner-mac").take_over!
    assert_match(/Gone/, failed("console.act", { "session" => session["id"], "action" => "screenshot" }))
    assert_equal "lost", ConsoleSession.find(session["id"]).status
  end
end
