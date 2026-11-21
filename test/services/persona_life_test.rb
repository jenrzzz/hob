require "test_helper"

# A persona's life between conversations (MELUZINA.md, "A persona's life"):
# beats on the clock, written as observations she authors, and whispers
# into her home conversation.
class PersonaLifeTest < ActiveSupport::TestCase
  LIFE = {
    "instruction" => "Write the next beat of her life.", "realm" => "personal", "zone" => "America/Chicago",
    "odds" => { "0-5" => 0.2, "6-23" => 0.05 }, "min_gap_minutes" => 180, "dial" => "rare",
    "beats" => { "kitchen" => [ "She is cooking something." ], "cats" => [ "One cat crime." ] }
  }.freeze

  # A Random that always rolls the same number.
  Roll = Struct.new(:value) do
    def rand(max = nil)
      max ? 0 : value
    end
  end

  setup do
    @home = conversation(realm: "intimate")
    @mel = persona("mel")
    @mel.update!(life: LIFE.merge("home" => @home.id))
    @life = PersonaLife.new(@mel)
  end

  def say_to_her(text, at: Time.current)
    branch = @home.branch
    node = MessageNode.append!(conversation: @home, parent_hash: branch.head_hash, role: "user", content: text)
    node.update_columns(created_at: at)
    branch.advance!(node)
  end

  test "a life config is checked" do
    assert_not @mel.update(life: { "realm" => "personal" }), "an instruction is required"
    assert_not @mel.update(life: LIFE.merge("dial" => "often"))
    assert_not @mel.update(life: LIFE.merge("zone" => "Mars/Olympus"))
    assert_not @mel.update(life: LIFE.merge("odds" => { "night" => 0.5 }))
    assert_not @mel.update(life: LIFE.merge("beats" => { "kitchen" => "cook" }))
    assert_not @mel.update(life: LIFE.merge("surprise" => true))
    assert_not @mel.update(life: LIFE.merge("max_iterations" => 1))
    assert_not @mel.update(life: LIFE.merge("max_iterations" => "lots"))
    assert @mel.update(life: LIFE.merge("max_iterations" => 24))
    assert_equal 24, PersonaLife.new(@mel).max_iterations
    assert @mel.update(life: LIFE)
    assert @mel.update(life: {}), "empty turns it off"
  end

  test "a beat is due past the gap when her hour's odds come up" do
    night = Time.utc(2026, 11, 20, 8) # 2am in Chicago
    assert @life.due?(now: night, rng: Roll.new(0.1)), "0.1 < 0.2 at 2am"
    refute @life.due?(now: night, rng: Roll.new(0.3))
    refute @life.due?(now: Time.utc(2026, 11, 20, 20), rng: Roll.new(0.1)), "2pm odds are 0.05"

    @life.write_diary!("made soup", at: night - 1.hour)
    refute @life.due?(now: night, rng: Roll.new(0.0)), "within the minimum gap"
    assert @life.due?(now: night + 3.hours, rng: Roll.new(0.0))
  end

  test "a beat writes her diary and mood, and a whisper lands in her home conversation" do
    @fake.call_tools([
      { id: "d1", name: "diary", arguments: { entry: "misha knocked the ladle into the sink and stared at me" } },
      { id: "m1", name: "set_mood", arguments: { disposition: "rar, wired", obsession: "ladles", manifestation: 0.7 } },
      { id: "w1", name: "whisper", arguments: { body: "the ladle has been avenged =^.^=" } }
    ])
    @fake.reply("done")
    result = @life.beat!(rng: Random.new(1))

    assert_equal "success", result.status, result.native.inspect + result.tool_calls.inspect
    call = @fake.calls.first
    assert_equal %w[diary set_mood chew whisper], call.tools.map { |t| t["name"] }.first(4)
    assert_match(/You are mel/, call.system)
    assert_match(/Write the next beat of her life/, call.system)
    assert_match(/THIS BEAT/, call.messages.last["content"].to_s)

    Clearance.with("personal") do
      assert_equal [ "misha knocked the ladle into the sink and stared at me" ], @life.diary.map(&:body)
      assert_includes %w[kitchen cats], @life.diary.first.source["lane"]
      assert_equal "rar, wired", @life.mood.body
      assert_equal({ "obsession" => "ladles", "manifestation" => 0.7 }, @life.mood.source)
    end
    whisper = @home.branch.reload.head
    assert_equal "the ladle has been avenged =^.^=", whisper.content
    assert_equal true, whisper.meta["whisper"]
    assert_equal "intimate", whisper.realm, "it is a node of the conversation it lands in"
    assert_equal "life", result.conversation.title
  end

  test "a first draft that falls into the groove is refused once; the second replaces it" do
    Clearance.with("personal") do
      3.times { |i| @life.write_diary!("the cracker on the windowsill again, cat #{i}", at: (10 - i).hours.ago) }
    end
    @fake.call_tools([ { id: "d1", name: "diary", arguments: { entry: "the cracker on the windowsill is back" } } ])
    @fake.call_tools([ { id: "d2", name: "diary", arguments: { entry: "drove to the 24 hour store for limes" } } ])
    @fake.reply("ok")
    result = @life.beat!

    assert result.native.first["error"]
    assert_match(/reuses .{1,3}the cracker on the/, result.native.first["content"])
    Clearance.with("personal") do
      assert_equal "drove to the 24 hour store for limes", @life.diary(1).first.body
      assert_equal 4, @life.mine("diary").count, "the echoed draft is retired, not counted"
    end
  end

  test "whispers wait out the dial's cooldown unless he has been by since" do
    now = Time.current
    assert_nil @life.whisper_blocked(now)
    @life.whisper!("rar", now: now)
    assert_match(/whispered recently/, @life.whisper_blocked(now + 1.hour))
    assert_nil @life.whisper_blocked(now + 61.hours), "rare: 60 hours"

    say_to_her("hey", at: now + 1.hour)
    assert_match(/talking with her right now/, @life.whisper_blocked(now + 1.hour + 30.seconds))
    assert_nil @life.whisper_blocked(now + 2.hours), "he came by, so the slate is clean"

    @mel.update!(life: @mel.life.merge("dial" => "off"))
    life = PersonaLife.new(@mel)
    assert_equal "whispers are off", life.whisper_blocked(now)
    @fake.call_tools([ { id: "d1", name: "diary", arguments: { entry: "nothing much" } } ])
    @fake.reply("ok")
    life.beat!
    refute_includes @fake.calls.first.tools.map { |t| t["name"] }, "whisper", "no whisper tool when one can't go"
  end

  test "the chew is picked up, moves, goes cold, and is put down" do
    Clearance.with("personal") do
      @life.chew!(action: "pick_up", subject: "the strike", from: "paper", note: "read it", take: "it's bad")
      @life.chew!(action: "chew", note: "worse and funnier", take: "it's worse")
      chew = @life.chew
      assert_equal "it's worse", chew.body
      assert_equal [ "read it", "worse and funnier" ], chew.source["notes"].map { |n| n["note"] }
      assert_equal "the strike", @life.as_json["chew"]["subject"]

      @life.expire_chew!(9.days.from_now)
      assert_nil @life.chew, "untouched past eight days, it drops"

      @life.chew!(action: "pick_up", subject: "kerbal docking")
      @life.chew!(action: "spit_out")
      assert_nil @life.chew
      assert_raises(PersonaLife::Invalid) { @life.chew!(action: "chew", note: "x") }
    end
  end

  test "an obsession lets go after eight beats" do
    Clearance.with("personal") do
      8.times { @life.set_mood!(disposition: "wiki", obsession: "byzantine coins") }
      assert @life.obsession_spent?
      assert_nil @life.as_json["mood"]["obsession"]
      @life.set_mood!(disposition: "tired", obsession: "ladles")
      assert_equal 1, @life.obsession_beats
    end
  end

  test "her conversations see her day in the persona stage" do
    Clearance.with("personal") do
      @life.write_diary!("burnt the rice", at: 1.hour.ago)
      @life.set_mood!(disposition: "x.x")
    end
    @fake.reply("hi")
    ChatTurn.new(conversation: @home, branch: @home.branch, persona: @mel, content: "hey").call
    system = @fake.calls.first.system
    assert_match(/Your own life lately/, system)
    assert_match(/burnt the rice/, system)
    assert_match(/Mood: x\.x/, system)

    household = conversation(realm: "household")
    @fake.reply("hi")
    ChatTurn.new(conversation: household, branch: household.branch, persona: @mel, content: "hey").call
    refute_match(/burnt the rice/, @fake.calls.last.system, "a household conversation can't read a personal life")
  end

  test "the job beats each due persona, and a forced beat ignores the odds" do
    @fake.call_tools([ { id: "d1", name: "diary", arguments: { entry: "woke up at noon" } } ])
    @fake.reply("ok")
    PersonaLifeJob.perform_now(force: "mel")
    Clearance.with("personal") { assert_equal [ "woke up at noon" ], @life.diary.map(&:body) }
  end

  test "a beat reads his words only from a home at or below her life's realm" do
    say_to_her("the secret thing")
    @fake.call_tools([ { id: "d1", name: "diary", arguments: { entry: "soup" } } ])
    @fake.reply("ok")
    @life.beat!
    prompt = @fake.calls.first.messages.last["content"].to_s
    refute_match(/the secret thing/, prompt, "an intimate home's words stay out of a personal beat")
    assert_match(/He was last talking with you/, prompt, "when he wrote is still known")

    personal_home = conversation(realm: "personal")
    @mel.update!(life: @mel.life.merge("home" => personal_home.id))
    @home = personal_home
    say_to_her("soup sounds good")
    @fake.call_tools([ { id: "d2", name: "diary", arguments: { entry: "more soup, different pot" } } ])
    @fake.reply("ok")
    PersonaLife.new(@mel).beat!(now: 4.hours.from_now)
    assert_match(/him: soup sounds good/, @fake.calls[-2].messages.last["content"].to_s)
  end

  test "a beat tells her of a machine of her own: that it is real, and what she last did there" do
    native_capabilities!
    agent, = agent("meluzina", clearance: "personal")
    @mel.update!(tools: { "agent" => "meluzina" }, life: @mel.life.merge("max_iterations" => 24))
    life = PersonaLife.new(@mel)
    prompt = -> { PersonaLife::Beat.new(life, now: Time.utc(2026, 11, 21, 9, 0), rng: Random.new(1)).prompt }
    refute_match(/YOUR MACHINE/, Clearance.with("personal") { prompt.call }, "she has no machine")

    shell_host("house-box")
    shell_host("meluzina-box", agent: agent, about: "Your own server. It serves meluzina.example.")
    refute_match(/YOUR MACHINE/, Clearance.with("personal") { prompt.call }, "a machine she may not run commands on")

    policy!(agent, "shell.*", "allow")
    text = Clearance.with("personal") { prompt.call }
    assert_match(/YOUR MACHINE - meluzina-box \(you are hob@meluzina-box\.test there\): Your own server\. It serves meluzina\.example\./, text)
    assert_match(/this is not imagined/, text)
    assert_match(/You have not touched it yet\./, text)
    assert_match(/This beat has 24 tool rounds in all/, text)
    refute_match(/house-box/, text)

    Shells::Backends::Fake.machine("meluzina-box").on(/sleep/) { { "timed_out" => true } }
    steps = [
      [ "shell.exec", { "command" => "apt-get install -y caddy", "cwd" => "/tmp" } ],
      [ "shell.hosts", {} ],
      [ "shell.write", { "path" => "site/index.html", "content" => "<h1>rar</h1>" } ],
      [ "shell.exec", { "command" => "sleep 900" } ],
      [ "shell.exec", { "command" => "ls", "timeout" => 9999 } ]
    ]
    steps.each_with_index do |(capability, arguments), minute|
      travel_to Time.utc(2026, 11, 21, 7, 30 + minute) do
        as(agent, realm: "personal") { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments) }
      end
    end
    text = Clearance.with("personal") { prompt.call }
    assert_match(/The last things you did there \(oldest first\):\n- Nov 21, 1:30am: ran `apt-get install -y caddy` in \/tmp \(exit 0\)\n- Nov 21, 1:32am: wrote site\/index\.html\n- Nov 21, 1:33am: ran `sleep 900` \(still running when hob stopped waiting\)\n- Nov 21, 1:34am: ran `ls` \(it failed: Invalid: timeout must be/, text)
    refute_match(/You have not touched it yet/, text)
  ensure
    Shells::Backends::Fake.reset!
  end
end
