require "test_helper"

# A channel's pulse (IRC.md, "The pulse"): a room gone quiet, or gone round
# in the same two voices, wakes its host persona to bring it something,
# often a seed from the room's tray.
class IrcPulseTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  WAKES = { "gap_minutes" => 20, "per_day" => 8, "delay_minutes" => 3 }.freeze
  LIFE = { "instruction" => "Write the next beat of her life.", "realm" => "personal", "zone" => "America/Chicago",
           "odds" => { "0-23" => 1.0 }, "min_gap_minutes" => 180, "wakes" => WAKES }.freeze
  NOW = Time.utc(2026, 11, 24, 15, 0)

  setup do
    travel_to NOW
    native_capabilities!
    @meluzina, = agent("meluzina", clearance: "personal")
    @twilight, = agent("twilight", clearance: "personal")
    @trixie, = agent("trixie", clearance: "personal")
    [ @meluzina, @twilight, @trixie ].each { |a| policy!(a, "irc.*", "allow") }
    @mel = persona("mel")
    @mel.update!(life: LIFE, tools: { "agent" => "meluzina" })
    [ @meluzina, @twilight, @trixie ].each { |a| on(a) { Irc.join(a, "#garden") } }
    @garden = Clearance.with("personal") { IrcChannel.find_by!(name: "#garden") }
    @garden.update!(pulse: { "host" => "mel" })
  end

  def on(who, realm: "personal", &) = as(who, realm: realm, &)

  def say(who, body)
    on(who) { Irc.say(who, to: "#garden", body: body) }
  end

  def pulse = Irc::Pulse.new(@garden.reload)

  def plant(*bodies)
    bodies.map.with_index { |body, i| @garden.seeds.create!(kind: "archive", title: "stretch #{i}", body: body, key: "a#{i}") }
  end

  def wake_job_queued?
    enqueued_jobs.any? { |job| job[:job] == PersonaWakeJob && job[:args] == [ @mel.id ] }
  end

  test "a pulse is checked" do
    assert_empty Irc::Pulse.problems("host" => "mel", "quiet_minutes" => 60)
    assert_includes Irc::Pulse.problems("quiet_minutes" => 60).join, "needs a host"
    assert_includes Irc::Pulse.problems("host" => "mel", "per_day" => 0).join, "per_day is a whole number from 1 to 24"
    assert_includes Irc::Pulse.problems("host" => "mel", "beat" => 1).join, "unknown keys: beat"
  end

  test "a quiet room needs something, a busy one does not, and her own unanswered drop is not quiet" do
    say(@twilight, "trixie: peer review?")
    say(@trixie, "twilight: never")
    assert_nil Clearance.with("personal") { pulse.reason }

    travel 4.hours
    assert_match(/nobody has said anything there for about 4 hours/, Clearance.with("personal") { pulse.reason })

    say(@meluzina, "who wants a game")
    travel 4.hours
    assert_nil Clearance.with("personal") { pulse.reason }, "she spoke last: the room has her drop already"
  end

  test "the same two voices for a stretch is a loop" do
    12.times do
      say(@twilight, "trixie, no")
      say(@trixie, "twilight, yes")
    end
    assert_equal "the last 24 lines there have all been trixie and twilight, back and forth",
                 Clearance.with("personal") { pulse.reason }

    say(@meluzina, "enough")
    assert_nil Clearance.with("personal") { pulse.reason }
  end

  test "the sweep wakes the host once, then rests for its gap and its count" do
    say(@twilight, "anyone?")
    travel 4.hours
    assert_equal({ "#garden" => :pulsed }, Irc::Pulse.sweep)
    assert wake_job_queued?
    assert_equal "nobody has said anything there for about 4 hours", @mel.reload.wake.dig("pulse", "reason")
    assert_equal Time.current.utc.iso8601, @garden.reload.pulse_state["last_at"]

    travel 1.hour
    assert_equal({ "#garden" => :fine }, Irc::Pulse.sweep, "inside the gap")

    @garden.update!(pulse: { "host" => "mel", "gap_minutes" => 30, "per_day" => 1 })
    travel 1.hour
    assert_equal({ "#garden" => :fine }, Irc::Pulse.sweep, "one a day")
  end

  test "a host whose agent is not in the room, or without wakes, is not woken" do
    @garden.update!(pulse: { "host" => "nobody" })
    travel 4.hours
    assert_equal({ "#garden" => :no_host }, Irc::Pulse.sweep)

    @garden.update!(pulse: { "host" => "mel" })
    @mel.update!(life: LIFE.except("wakes"))
    assert_equal({ "#garden" => :wakes_off }, Irc::Pulse.sweep)
    assert_nil @garden.reload.pulse_state["last_at"], "a pulse that woke nobody is not counted"
  end

  test "the woken beat says why, shows the tray without its words, and take_seed hands one over once" do
    plant("Robyn, 2021: the wish only works if you mean the ugly part too.")
    say(@twilight, "anyone?")
    travel 4.hours
    Irc::Pulse.sweep
    seed = @garden.seeds.first

    @fake.call_tools([ { id: "t1", name: "take_seed", arguments: { id: seed.id } } ])
    @fake.call_tools([ { id: "t2", name: "take_seed", arguments: { id: seed.id } } ])
    @fake.call_tools([ { id: "s1", name: "irc_say", arguments: { to: "#garden", body: "a wish, from the archive" } } ])
    @fake.reply("")
    travel 3.minutes
    assert_equal :woken, PersonaLife::Wake.new(PersonaLife.new(@mel.reload)).run!

    page = @fake.calls.first.messages.last["content"].to_s
    assert_match(/HOSTING - #garden needs something: nobody has said anything there for about 4 hours\./, page)
    assert_match(/\[#{seed.id}\] archive: stretch 0/, page)
    refute_match(/ugly part/, page, "the tray shows what a seed is, never its words")
    refute_match(/WOKEN -/, page, "nobody named her")
    assert_includes @fake.calls.first.tools.map { |t| t["name"] }, "take_seed"

    seed.reload
    assert seed.taken_at, "taken"
    assert_equal @meluzina, seed.taken_by
    assert_equal [ "meluzina", "a wish, from the archive" ], IrcLine.spoken.in_order.last.then { |l| [ l.nick, l.body ] }
    assert_nil @mel.reload.wake["pulse"], "the pulse is answered by the beat"
  end

  test "a wake that is dropped clears the pulse with it" do
    say(@twilight, "anyone?")
    travel 4.hours
    Irc::Pulse.sweep
    @mel.update!(life: LIFE.merge("wakes" => WAKES.merge("per_day" => 1)))
    @mel.reload.update_columns(wake: @mel.wake.merge("woken" => [ Time.current.utc.iso8601 ]))
    travel 3.minutes
    assert_equal "1 wakes in a day already", PersonaLife::Wake.new(PersonaLife.new(@mel.reload)).run!
    assert_nil @mel.reload.wake["pulse"]
  end
end
