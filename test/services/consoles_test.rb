require "test_helper"

# Consoles (KVM.md): sessions for a goal on a KVM, actions checked before
# they leave hob, one session at a time, short lives, over the in-memory
# Fake. RLS decides which consoles exist for a call; the session row decides
# whose a session is.
class ConsolesTest < ActiveSupport::TestCase
  Fake = Consoles::Backends::Fake

  setup do
    @mac = kvm("jenner-mac", machine: "Jenner's MacBook")
    @device = Fake.device("jenner-mac")
  end

  teardown { Fake.reset! }

  def open(**attrs)
    Consoles.open(**{ goal: "turn off Focus mode for Jenner" }.merge(attrs))
  end

  test "open: a goal, the only visible console, and a frame comes back with its size" do
    result = open
    session = result["session"]
    assert_match(/\A[0-9A-HJKMNP-TV-Z]{26}\z/, session["id"])
    assert_equal "jenner-mac", session["console"]
    assert_equal "Jenner's MacBook", session["machine"]
    assert_equal "open", session["status"]
    assert_equal 0, session["steps"]
    assert_equal 1280, result["screen"]["width"]
    assert_equal 720, result["screen"]["height"]
    assert_match(/PNG fake frame 1/, Base64.decode64(result["screen"]["data"]))
    assert_equal true, result["video"]["ready"]

    row = ConsoleSession.find(session["id"])
    assert_equal @principal, row.principal
    assert_equal "personal", row.realm
    assert_equal "k1", row.remote_id
    assert_equal ConsoleSession::DEFAULT_TTL, row.ttl
    assert_in_delta Time.current + ConsoleSession::DEFAULT_TTL, row.expires_at, 5
    assert_equal [ [ :open, ConsoleSession::DEFAULT_TTL, nil ] ], @device.calls
  end

  test "open: the goal is required, the console must be named when there are two, ttl and scale are checked" do
    assert_raises(Consoles::Invalid) { open(goal: " ") }
    kvm("tessa-pc")
    assert_match(/name the console: one of jenner-mac, tessa-pc/, assert_raises(Consoles::Invalid) { open }.message)
    assert_raises(Consoles::NotFound) { open(console: "nope") }
    assert_raises(Consoles::Invalid) { open(console: "jenner-mac", ttl: "soon") }
    assert_raises(Consoles::Invalid) { open(console: "jenner-mac", scale: 10) }
    open(console: "jenner-mac", ttl: 5, scale: 1920)
    assert_equal [ :open, ConsoleSession::MIN_TTL, 1920 ], @device.calls.last, "ttl is clamped"
    Console.update_all(enabled: false)
    assert_raises(Consoles::NotFound) { open(console: "jenner-mac") }
  end

  test "one session at a time: a second open is busy, and the opener is told which session is theirs" do
    id = open["session"]["id"]
    error = assert_raises(Consoles::Unavailable) { open }
    assert_match(/in use by your session #{id}/, error.message)

    other, = agent("other", clearance: "personal")
    error = as(other, realm: "personal") { assert_raises(Consoles::Unavailable) { open } }
    assert_match(/in use by another session\z/, error.message)
    assert_equal 1, @device.sessions.size, "hob refused before asking the bridge"

    Consoles.close(id)
    assert open["session"]["id"]
  end

  test "act: every action is checked, counted, and answered with a fresh frame" do
    id = open["session"]["id"]
    result = Consoles.act(id, "action" => "left_click", "x" => 640, "y" => 12, "modifiers" => "cmd")
    assert_equal 1, result["session"]["steps"]
    assert_match(/frame 2/, Base64.decode64(result["screen"]["data"]))
    assert_equal [ :act, "k1", { "action" => "left_click", "x" => 640, "y" => 12, "modifiers" => "cmd" } ], @device.calls.last

    Consoles.act(id, "action" => "left_click_drag", "from" => [ 1, 2 ], "to" => [ 30, 40 ])
    Consoles.act(id, "action" => "scroll", "x" => 10, "y" => 10, "direction" => "down", "amount" => 5)
    Consoles.act(id, "action" => "type", "text" => "Focus")
    Consoles.act(id, "action" => "key", "key" => "cmd+space")
    Consoles.act(id, "action" => "key", "key" => "cmd++")
    Consoles.act(id, "action" => "hold_key", "key" => "alt", "seconds" => 2)
    Consoles.act(id, "action" => "wait", "seconds" => 1.5)
    Consoles.act(id, "action" => "screenshot")
    Consoles.act(id, "action" => "mouse_move", "x" => 100.0, "y" => "200")
    assert_equal({ "action" => "mouse_move", "x" => 100, "y" => 200 }, @device.calls.last.last)
    assert_equal 10, ConsoleSession.find(id).steps
  end

  test "act: an unknown action or argument is refused, never ignored, and nothing reaches the bridge" do
    id = open["session"]["id"]
    before = @device.calls.size
    refusals = [
      { "action" => "power_off" },
      { "action" => "factoryReset" },
      { "action" => "screenshot", "x" => 1 },
      { "action" => "left_click", "x" => 1 },
      { "action" => "left_click", "x" => -1, "y" => 1 },
      { "action" => "left_click", "x" => 1, "y" => 99_999 },
      { "action" => "left_click", "x" => "here", "y" => 1 },
      { "action" => "left_click", "x" => 1, "y" => 1, "button" => "left" },
      { "action" => "left_click_drag", "from" => [ 1 ], "to" => [ 1, 2 ] },
      { "action" => "scroll", "x" => 1, "y" => 1, "direction" => "sideways" },
      { "action" => "scroll", "x" => 1, "y" => 1, "direction" => "up", "amount" => 500 },
      { "action" => "type", "text" => "" },
      { "action" => "type", "text" => "x" * (Consoles::MAX_TEXT + 1) },
      { "action" => "key", "key" => "cmd + space" },
      { "action" => "key", "key" => "cmd+" },
      { "action" => "hold_key", "key" => "alt", "seconds" => 11 },
      { "action" => "wait", "seconds" => 31 },
      { "action" => "wait" }
    ]
    refusals.each do |arguments|
      assert_raises(Consoles::Invalid, arguments.inspect) { Consoles.act(id, arguments) }
    end
    assert_equal before, @device.calls.size
    assert_equal 0, ConsoleSession.find(id).steps
  end

  test "a session takes at most MAX_STEPS steps" do
    id = open["session"]["id"]
    ConsoleSession.find(id).update!(steps: ConsoleSession::MAX_STEPS)
    assert_match(/taken its 500 steps/, assert_raises(Consoles::Invalid) { Consoles.act(id, "action" => "screenshot") }.message)
  end

  test "screen: a fresh frame without a step, at a scale" do
    id = open["session"]["id"]
    result = Consoles.screen(id, scale: 1920)
    assert_equal 1920, result["screen"]["width"]
    assert_equal 0, result["session"]["steps"]
  end

  test "a session is its opener's: another agent gets not found; a person reaches it to look or close" do
    muse, = agent("muse", clearance: "personal")
    id = as(muse, realm: "personal") { open["session"]["id"] }
    other, = agent("other", clearance: "personal")
    as(other, realm: "personal") do
      assert_raises(Consoles::NotFound) { Consoles.act(id, "action" => "screenshot") }
      assert_raises(Consoles::NotFound) { Consoles.screen(id) }
      assert_raises(Consoles::NotFound) { Consoles.close(id) }
      assert_equal [], Consoles.sessions.to_a
    end
    assert_equal [ id ], Consoles.sessions.map(&:id), "a person sees every open session"
    assert Consoles.screen(id)["screen"]
    assert_equal "closed by #{@principal.name}", Consoles.close(id)["close_reason"]
    assert_equal "closed", Consoles.close(id)["status"], "closing twice is the row as it stands"
  end

  test "a household agent cannot see a personal console" do
    tessa_muse, = agent("tessa-muse", clearance: "household")
    as(tessa_muse, realm: "household") do
      assert_match(/no console is visible/, assert_raises(Consoles::NotFound) { open }.message)
      assert_raises(Consoles::NotFound) { open(console: "jenner-mac") }
      assert_equal [], Consoles.consoles.to_a
    end
  end

  test "takeover: a person opening the KVM ends the session as lost, and the KVM is free again" do
    id = open["session"]["id"]
    @device.take_over!
    assert_raises(Consoles::Gone) { Consoles.act(id, "action" => "screenshot") }
    row = ConsoleSession.find(id)
    assert_equal "lost", row.status
    assert_match(/another session connected/, row.close_reason)
    assert_match(/is lost/, assert_raises(Consoles::Gone) { Consoles.screen(id) }.message)
    assert open["session"]["id"]
  end

  test "expiry: a step extends the idle deadline; the idle ttl and the half hour end it, here and on the bridge" do
    id = open(ttl: 60)["session"]["id"]
    travel 50.seconds
    Consoles.act(id, "action" => "screenshot")
    travel 50.seconds
    Consoles.act(id, "action" => "screenshot")
    travel 61.seconds
    assert_match(/no step for 60 seconds/, assert_raises(Consoles::Gone) { Consoles.act(id, "action" => "screenshot") }.message)
    assert_equal "expired", ConsoleSession.find(id).status
    assert_equal [ :close, "k1" ], @device.calls.last

    id = open(ttl: 900)["session"]["id"]
    travel 14.minutes
    Consoles.act(id, "action" => "screenshot")
    travel 14.minutes
    Consoles.act(id, "action" => "screenshot")
    assert_equal ConsoleSession.find(id).created_at + 30.minutes, ConsoleSession.find(id).expires_at
    travel 3.minutes
    assert_match(/30 minutes limit/, assert_raises(Consoles::Gone) { Consoles.screen(id) }.message)
  end

  test "sweep! ends overdue sessions on the bridge and the row; an overdue session does not keep the console busy" do
    id = open(ttl: 30)["session"]["id"]
    travel 31.seconds
    assert_equal [ id ], Consoles.sweep!
    assert_equal "expired", ConsoleSession.find(id).status
    assert_equal "closed by the caller", @device.sessions["k1"]["closed"]
    assert_equal [], Consoles.sweep!

    id = open(ttl: 30)["session"]["id"]
    travel 31.seconds
    assert open["session"]["id"], "the stale one was ended on the way in"
    assert_equal "expired", ConsoleSession.find(id).status
  end

  test "sweep! still ends the row when the bridge is away" do
    id = open(ttl: 30)["session"]["id"]
    travel 31.seconds
    Fake.fail!("jenner-mac", Consoles::Unavailable.new("the bridge is down"))
    ConsoleSweepJob.perform_now
    assert_equal "expired", ConsoleSession.find(id).status
  end

  test "a bridge that is away fails the open with its reason, and no row is left" do
    Fake.fail!("jenner-mac", Consoles::Unavailable.new("the bridge is down"))
    assert_match(/the bridge is down/, assert_raises(Consoles::Unavailable) { open }.message)
    assert_equal 0, ConsoleSession.count
  end
end
