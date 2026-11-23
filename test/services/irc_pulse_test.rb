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

  test "the sweep calls the host; the pulse is counted when her beat runs, then rests for its gap and its count" do
    say(@twilight, "anyone?")
    travel 4.hours
    assert_equal({ "#garden" => :pulsed }, Irc::Pulse.sweep)
    assert wake_job_queued?
    assert_equal "nobody has said anything there for about 4 hours", @mel.reload.wake.dig("pulse", "reason")
    assert_nil @garden.reload.pulse_state["last_at"], "not counted until she is up"

    @fake.reply("")
    travel 3.minutes
    assert_equal :woken, PersonaLife::Wake.new(PersonaLife.new(@mel.reload)).run!
    assert_equal Time.current.utc.iso8601, @garden.reload.pulse_state["last_at"]
    assert_equal 1, @garden.pulse_state["fired"].size

    travel 1.hour
    assert_equal({ "#garden" => :fine }, Irc::Pulse.sweep, "inside the gap")

    @garden.update!(pulse: { "host" => "mel", "gap_minutes" => 30, "per_day" => 1 })
    travel 1.hour
    assert_equal({ "#garden" => :fine }, Irc::Pulse.sweep, "one a day")
  end

  test "a long stretch on nothing new is stale, until a seed is taken or she hosts" do
    @garden.update!(pulse: { "host" => "mel", "stale_lines" => 12 })
    seed, = plant("a wish")
    4.times do
      say(@twilight, "trixie, the margin")
      say(@trixie, "meluzina, credited")
      say(@meluzina, "twilight, mostly")
    end
    assert_equal "12 lines have been said there since anything new was brought in",
                 Clearance.with("personal") { pulse.reason }, "though she spoke last, and three voices are no loop"

    travel 1.minute
    seed.update!(taken_at: Time.current, taken_by: @twilight)
    travel 1.minute
    say(@twilight, "from the tray: a wish")
    assert_nil Clearance.with("personal") { pulse.reason }
  end

  test "hosting is on the room's count, not hers: past her wakes a day she still hosts, and it is not one of them" do
    @mel.update!(life: LIFE.merge("wakes" => WAKES.merge("per_day" => 1)))
    @mel.reload.update_columns(wake: { "last_at" => (NOW - 1.hour).utc.iso8601, "streak" => 5,
                                       "woken" => [ (NOW - 1.hour).utc.iso8601 ] })
    say(@twilight, "anyone?")
    travel 4.hours
    Irc::Pulse.sweep
    @fake.reply("")
    travel 3.minutes
    assert_equal :woken, PersonaLife::Wake.new(PersonaLife.new(@mel.reload)).run!
    assert_equal 1, @mel.reload.wake["woken"].size
    assert_equal 0, @mel.wake["streak"], "hosting ends her run"
  end

  test "a pulse does not wait behind a run of names backing off" do
    say(@twilight, "anyone?")
    travel 4.hours
    far = Time.current + 2.hours
    @mel.update_columns(wake: { "due_at" => far.utc.iso8601, "calls" => [] })
    assert_equal({ "#garden" => :pulsed }, Irc::Pulse.sweep)
    assert_equal (Time.current + 3.minutes).utc.iso8601, @mel.reload.wake["due_at"]
    assert wake_job_queued?
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

  test "a wake that is dropped clears the pulse with it, and the room is not charged" do
    say(@twilight, "anyone?")
    travel 4.hours
    Irc::Pulse.sweep
    @mel.update!(life: LIFE.merge("budget" => { "tokens_per_day" => 1_000 }))
    UsageEvent.create!(ref: "persona/mel/life", created_at: Time.current - 1.hour, status: "success",
                       units: { "input_tokens" => 2_000 })
    travel 3.minutes
    assert_equal "over her token budget", PersonaLife::Wake.new(PersonaLife.new(@mel.reload)).run!
    assert_nil @mel.reload.wake["pulse"]
    assert_nil @garden.reload.pulse_state["last_at"]
    assert_equal({ "#garden" => :over_budget }, Irc::Pulse.sweep, "nor is she called again while she cannot speak")
  end
end
