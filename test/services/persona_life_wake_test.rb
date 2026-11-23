require "test_helper"

# A persona woken by being spoken to on hob's IRC (IRC.md, "Woken"): a line
# that names her agent, or a DM to it, queues one beat soon after, within a
# gap and a daily count, at a realm her life is kept at.
class PersonaLifeWakeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  WAKES = { "gap_minutes" => 20, "per_day" => 8, "delay_minutes" => 3 }.freeze
  LIFE = { "instruction" => "Write the next beat of her life.", "realm" => "personal", "zone" => "America/Chicago",
           "odds" => { "0-23" => 1.0 }, "min_gap_minutes" => 180, "wakes" => WAKES }.freeze
  NOW = Time.utc(2026, 11, 24, 15, 0)

  setup do
    travel_to NOW
    native_capabilities!
    @person = Principal.find_or_create_by!(name: "jenner") { |p| p.kind = "human"; p.max_clearance = "intimate" }
    @meluzina, = agent("meluzina", clearance: "personal")
    @twilight, = agent("twilight", clearance: "personal")
    @skipsy, = agent("skipsy", clearance: "personal")
    @twilights, = agent("twilights", clearance: "personal")
    [ @meluzina, @twilight, @skipsy, @twilights ].each { |a| policy!(a, "irc.*", "allow") }
    @mel = persona("mel")
    @mel.update!(life: LIFE, tools: { "agent" => "meluzina" })
    @twi = persona("twi")
    @twi.update!(life: LIFE, tools: { "agent" => "twilight" })
    [ @meluzina, @twilight, @skipsy, @twilights ].each { |a| on(a) { Irc.join(a, "#garden") } }
  end

  def on(who, realm: "personal", &) = as(who, realm: realm, &)

  def say(who, to, body, realm: "personal")
    on(who, realm: realm) { Irc.say(who, to: to, body: body) }
  end

  def wake_jobs
    enqueued_jobs.select { |job| job["job_class"] == "PersonaWakeJob" || job[:job] == PersonaWakeJob }
  end

  def woken?(persona)
    wake_jobs.any? { |job| job[:args] == [ persona.id ] } && persona.reload.wake["due_at"].present?
  end

  # Runs queued wakes in the order they come due, the clock following them.
  def drain!(limit: 40)
    ran = 0
    while (job = wake_jobs.min_by { |j| j[:at].to_f })
      enqueued_jobs.delete(job)
      at = job[:at] && Time.zone.at(job[:at])
      travel_to(at) if at && at > Time.current
      PersonaWakeJob.perform_now(*ActiveJob::Arguments.deserialize(job[:args]))
      ran += 1
      flunk "wakes never settled" if ran > limit
    end
    ran
  end

  def answer(body = "meluzina twilight: here")
    @fake.call_tools([ { id: "r1", name: "irc_read", arguments: { target: "#garden" } } ])
    @fake.call_tools([ { id: "s1", name: "irc_say", arguments: { to: "#garden", body: body } } ])
    @fake.reply("")
  end

  test "wakes are checked" do
    assert @mel.update(life: LIFE.merge("wakes" => {})), "the defaults read"
    assert_not @mel.update(life: LIFE.merge("wakes" => 5))
    assert_includes @mel.errors[:life].join, "life.wakes is {"
    assert_not @mel.update(life: LIFE.merge("wakes" => { "gap_minutes" => 1 }))
    assert_includes @mel.errors[:life].join, "gap_minutes is a whole number from 5 to 1440"
    assert_not @mel.update(life: LIFE.merge("wakes" => { "per_day" => 0 }))
    assert_includes @mel.errors[:life].join, "per_day is a whole number from 1 to 48"
    assert_not @mel.update(life: LIFE.merge("wakes" => { "delay_minutes" => "3" }))
    assert_includes @mel.errors[:life].join, "delay_minutes is a whole number"
    assert_not @mel.update(life: LIFE.merge("wakes" => { "snooze" => 3 }))
    assert_includes @mel.errors[:life].join, "unknown keys: snooze"
  end

  test "a name is matched as a word, any case" do
    assert PersonaLife::Wake.names?("Twilight: you there?", "twilight")
    assert PersonaLife::Wake.names?("ask twilight_2.", "twilight_2")
    refute PersonaLife::Wake.names?("the twilights are long", "twilight")
    refute PersonaLife::Wake.names?("twilight_2 knows", "twilight")
    refute PersonaLife::Wake.names?("ask twilight_2", "twilight_")
  end

  test "a line in a channel wakes only the persona it names, after the delay" do
    say(@skipsy, "#garden", "twilights, is twilight about?")
    assert woken?(@twi)
    refute woken?(@mel), "not named"
    assert_equal 1, wake_jobs.size, "twilights is no persona's agent; skipsy is the sender"
    assert_equal NOW + 3.minutes, Time.zone.at(wake_jobs.sole[:at])

    say(@meluzina, "#garden", "meluzina here, talking about myself")
    assert_equal 1, wake_jobs.size, "a line never wakes its own sender"
  end

  test "a DM wakes its other end" do
    say(@skipsy, "twilight", "hello you")
    assert woken?(@twi)
    assert_equal 1, wake_jobs.size
  end

  test "lines within the delay join one wake, and its page names who and where, never what" do
    say(@skipsy, "#garden", "twilight: the quince took")
    say(@skipsy, "#garden", "twilight, did you hear")
    say(@meluzina, "twilight", "psst")
    assert_equal 1, wake_jobs.size

    answer("here")
    assert_equal 1, drain!
    page = @fake.calls.first.messages.last["content"].to_s
    assert_match(/WOKEN - .*skipsy named you in #garden and meluzina wrote to you\./, page)
    refute_match(/quince|did you hear|psst/, page, "the lines reach her through irc_read, as data")
    refute_match(/THIS BEAT \(drawn at random/, page, "a wake draws no lane")
    names = @fake.calls.first.tools.map { |t| t["name"] }
    assert_equal %w[diary set_mood], names & PersonaLife::Tools::DEFS.map { |d| d["name"] }, "no chew, no whisper"
    assert_includes names, "irc_say"
    assert_equal [ "twilight", "here" ], IrcLine.spoken.in_order.last.then { |l| [ l.nick, l.body ] }
    assert_equal({ "last_at" => NOW.advance(minutes: 3).utc.iso8601, "woken" => [ NOW.advance(minutes: 3).utc.iso8601 ] },
                 @twi.reload.wake)
  end

  test "a wake whose lines she already read is dropped" do
    say(@skipsy, "#garden", "twilight: hi")
    on(@twilight) { Irc.read(@twilight, target: "#garden") }
    assert_equal 1, drain!
    assert_empty @fake.calls
    assert_empty @twi.reload.wake
  end

  test "a wake inside her gap waits for its end, and a scheduled beat keeps the wakes' gap" do
    Clearance.with("personal") { PersonaLife.new(@twi).write_diary!("a beat of her own", at: NOW - 10.minutes) }
    say(@skipsy, "#garden", "twilight?")
    answer("here")
    assert_equal 2, drain!, "deferred once, then run"
    assert_equal NOW + 10.minutes, Time.current
    assert_equal 1, @twi.reload.wake["woken"].size

    life = PersonaLife.new(@twi.reload)
    Clearance.with("personal") { life.mine("diary").update_all(observed_at: NOW - 1.day) }
    refute Clearance.with("personal") { life.due?(now: Time.current + 10.minutes, rng: Random.new(1)) },
           "within the wakes' gap of a wake, though the wake wrote no diary"
    assert Clearance.with("personal") { life.due?(now: Time.current + 21.minutes, rng: Random.new(1)) }
  end

  test "a wake's diary entry is marked, and counts toward the scheduled gap" do
    say(@skipsy, "#garden", "twilight?")
    @fake.call_tools([ { id: "d1", name: "diary", arguments: { entry: "skipsy called up the stairs." } } ])
    @fake.reply("")
    drain!
    life = PersonaLife.new(@twi.reload)
    entry = Clearance.with("personal") { life.diary.first }
    assert_equal({ "wake" => true }, entry.source)
    assert_equal true, Clearance.with("personal") { life.as_json }["diary"].last["wake"]
    refute Clearance.with("personal") { life.due?(now: Time.current + 1.hour, rng: Random.new(1)) }, "inside min_gap"
  end

  test "no wakes without life.wakes" do
    @twi.update!(life: LIFE.except("wakes"))
    say(@skipsy, "#garden", "twilight!")
    say(@skipsy, "twilight", "twilight!")
    assert_empty wake_jobs
  end

  test "two personas talking stop at the day's count" do
    wakes = { "gap_minutes" => 5, "per_day" => 3, "delay_minutes" => 1 }
    [ @mel, @twi ].each { |p| p.update!(life: LIFE.merge("wakes" => wakes)) }
    10.times { answer }
    say(@skipsy, "#garden", "twilight, ask mel")
    drain!

    assert_empty wake_jobs, "it settled"
    assert_equal 3, @mel.reload.wake["woken"].size
    assert_equal 3, @twi.reload.wake["woken"].size
    assert_equal 7, IrcLine.spoken.count, "skipsy's line and three answers each"
  end

  test "a mention in an intimate channel wakes a Mel-like life upstairs; a room above her wakes nobody" do
    @meluzina.update!(max_clearance: "intimate")
    celestia, = agent("celestia", clearance: "intimate")
    policy!(celestia, "irc.*", "allow")
    Clearance.with("intimate") { Irc.channel_by_person!("#upstairs", realm: "intimate", by: @person) }
    [ @meluzina, celestia ].each { |a| on(a, realm: "intimate") { Irc.join(a, "#upstairs") } }

    say(celestia, "#upstairs", "meluzina, come up", realm: "intimate")
    assert_empty wake_jobs, "a personal life holds no realm as high as the room"

    @mel.update!(life: LIFE.merge("beats" => { "kitchen" => [ "cook" ], "upstairs" => [ "go up" ] },
                                  "lane_realms" => { "upstairs" => "intimate" }))
    say(celestia, "#upstairs", "meluzina?", realm: "intimate")
    @fake.call_tools([ { id: "s1", name: "irc_say", arguments: { to: "#upstairs", body: "coming" } } ])
    @fake.reply("")
    drain!
    Clearance.with("intimate") do
      assert_equal "intimate", Conversation.where(kind: "pipeline", title: "life").order(:created_at).last.realm
      assert_equal [ "meluzina", "coming", "intimate" ], IrcLine.spoken.in_order.last.then { |l| [ l.nick, l.body, l.realm ] }
    end
    assert_match(/celestia named you in #upstairs/, @fake.calls.first.messages.last["content"].to_s)
  end

  test "a room below her life is answered at the life's realm" do
    @twi.update!(life: LIFE.merge("realm" => "personal"))
    say(@skipsy, "#garden", "twilight", realm: "household")
    answer("here")
    drain!
    Clearance.with("intimate") do
      assert_equal "personal", Conversation.where(kind: "pipeline", title: "life").order(:created_at).last.realm
    end
  end

  test "a wake and a scheduled beat of hers never run at once" do
    say(@skipsy, "#garden", "twilight?")
    job = wake_jobs.sole
    enqueued_jobs.delete(job)
    travel_to Time.zone.at(job[:at])
    # Another session (a test's connection is pinned, so not the pool's).
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    other = PG.connect(dbname: config[:database], host: config[:host], port: config[:port], user: config[:username],
                       password: config[:password])
    held = other.exec_params("SELECT pg_try_advisory_lock(hashtext($1))", [ "persona_life:#{@twi.id}" ]).getvalue(0, 0)
    assert_equal "t", held, "another beat of hers holds it"
    begin
      result = PersonaLife::Wake.new(PersonaLife.new(@twi)).run!
      assert_equal :busy, PersonaLife.new(@twi).exclusively { :ran }
    ensure
      other.close
    end
    assert_equal :busy, result
    assert_empty @fake.calls
    assert_equal Time.current + 2.minutes, Time.zone.at(wake_jobs.sole[:at]), "it tries again shortly"
  end
end
