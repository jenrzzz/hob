require "test_helper"

# A lane of a persona's life kept at a realm of its own (MELUZINA.md, "A
# persona's life", "A lane upstairs"): a beat drawn to it runs and writes
# there, reads her life across realms, and leaves nothing a reader below it
# can see; it never supersedes what is kept lower, and has no chew or whisper.
class PersonaLifeLanesTest < ActiveSupport::TestCase
  LIFE = {
    "instruction" => "Write the next beat of her life.", "realm" => "personal", "zone" => "America/Chicago",
    "odds" => { "0-23" => 1.0 }, "min_gap_minutes" => 180, "dial" => "open",
    "beats" => { "kitchen" => [ "She is cooking something." ], "upstairs" => [ "She goes up to #upstairs." ] },
    "lane_realms" => { "upstairs" => "intimate" }
  }.freeze
  NOW = Time.utc(2026, 11, 24, 15, 0)

  setup do
    native_capabilities!
    @person = Principal.find_or_create_by!(name: "jenner") { |p| p.kind = "human"; p.max_clearance = "intimate" }
    @agent, = agent("meluzina", clearance: "intimate")
    @celestia, = agent("celestia", clearance: "intimate")
    @home = conversation(realm: "intimate")
    @mel = persona("mel")
    @mel.update!(life: LIFE.merge("home" => @home.id), tools: { "agent" => "meluzina" })
    @life = PersonaLife.new(@mel)
    Clearance.with("intimate") { Irc.channel_by_person!("#upstairs", realm: "intimate", by: @person) }
  end

  def personal(&) = Clearance.with("personal", &)
  def upstairs(&) = Clearance.with("intimate", &)

  # The last lane written was the kitchen, so the next draw goes upstairs.
  def from_the_kitchen(at: NOW - 4.hours)
    personal do
      @life.write_diary!("made soup", lane: "kitchen", at: at)
      @life.set_mood!(disposition: "warm, floury", obsession: "soup", at: at)
    end
  end

  def beat_upstairs
    @fake.call_tools([ { id: "d1", name: "diary", arguments: { entry: "sat on the stairs with celestia." } },
                       { id: "m1", name: "set_mood", arguments: { disposition: "flushed", obsession: "her laugh" } } ])
    @fake.reply("")
    @life.beat!(now: NOW, rng: Random.new(1))
  end

  test "lane realms are checked" do
    assert_not @mel.update(life: LIFE.merge("lane_realms" => [ "upstairs" ]))
    assert_includes @mel.errors[:life].join, "maps lanes to realms"
    assert_not @mel.update(life: LIFE.merge("lane_realms" => { "attic" => "intimate" }))
    assert_includes @mel.errors[:life].join, "attic, which is not one of its beats"
    assert_not @mel.update(life: LIFE.merge("lane_realms" => { "upstairs" => "loft" }))
    assert_includes @mel.errors[:life].join, "loft is not a realm"
    assert_not @mel.update(life: LIFE.merge("lane_realms" => { "upstairs" => "household" }))
    assert_includes @mel.errors[:life].join, "below the life's realm"
    assert @mel.update(life: LIFE.merge("lane_realms" => { "upstairs" => "personal" })), "the life's own realm reads"
    assert @mel.update(life: LIFE)

    life = PersonaLife.new(@mel)
    assert_equal "intimate", life.realm_for("upstairs")
    assert_equal "personal", life.realm_for("kitchen")
    assert_equal "personal", life.realm_for(nil)
    assert_equal "intimate", life.top_realm
  end

  test "an elevated lane runs at its realm, and its IRC section shows the channel upstairs" do
    policy!(@agent, "irc.*", "allow")
    from_the_kitchen
    personal_page = personal { PersonaLife::Beat.new(PersonaLife.new(@mel), now: NOW, rng: Random.new(1)).prompt }
    refute_match(/#upstairs \(/, personal_page, "a personal beat cannot see the channel")

    @fake.call_tools([ { id: "j1", name: "irc_join", arguments: { channel: "#upstairs" } } ])
    @fake.call_tools([ { id: "s1", name: "irc_say", arguments: { to: "#upstairs", body: "anyone up here?" } },
                       { id: "d1", name: "diary", arguments: { entry: "went upstairs. nobody yet." } } ])
    @fake.reply("")
    @life.beat!(now: NOW, rng: Random.new(1))

    call = @fake.calls.first
    page = call.messages.last["content"].to_s
    assert_match(/She goes up to #upstairs/, page)
    assert_match(/Channels you are not in: #upstairs \(empty\)/, page)
    names = call.tools.map { |t| t["name"] }
    assert_equal %w[diary set_mood], names & PersonaLife::Tools::DEFS.map { |d| d["name"] }, "no chew, no whisper"
    assert_includes names, "irc_say"
    refute_match(/whisper/i, page)

    upstairs do
      assert_equal "intimate", Conversation.where(kind: "pipeline", title: "life").order(:created_at).last.realm
      line = IrcLine.spoken.in_order.last
      assert_equal [ "meluzina", "anyone up here?", "intimate" ], [ line.nick, line.body, line.realm ]
      request = @agent.sentinel_requests.find(line.sentinel_request_id)
      assert_equal [ "irc.say", "life", "intimate" ], [ request.capability.name, request.surface, request.realm ]
      entry = @life.diary.first
      assert_equal [ "went upstairs. nobody yet.", "upstairs", "intimate" ], [ entry.body, entry.source["lane"], entry.realm ]
    end
  end

  test "an elevated beat shows no more of IRC than her agent is cleared for" do
    @agent.update!(max_clearance: "personal")
    policy!(@agent, "irc.*", "allow")
    from_the_kitchen
    page = upstairs { PersonaLife::Beat.new(PersonaLife.new(@mel), now: NOW, rng: Random.new(1)).prompt }
    assert_match(/She goes up to #upstairs/, page, "the lane is drawn")
    assert_match(/You are meluzina there/, page)
    refute_match(/#upstairs \(/, page, "her agent acts at personal, where the channel does not exist")
  end

  test "an elevated beat reads her life across realms, and a personal reader sees nothing it wrote" do
    from_the_kitchen
    beat_upstairs

    page = @fake.calls.first.messages.last["content"].to_s
    assert_match(/Your current mood: warm, floury/, page, "she carries her mood up with her")
    assert_match(/- made soup/, page)

    personal do
      life = PersonaLife.new(@mel)
      assert_equal [ "made soup" ], life.diary.map(&:body)
      assert_equal "warm, floury", life.mood.body
      json = life.as_json
      assert_equal [ "made soup" ], json["diary"].map { |d| d["entry"] }
      assert_equal "warm, floury", json["mood"]["disposition"]
      refute_match(/celestia|flushed/, life.render)
      assert_equal NOW - 4.hours, life.last_beat_at
    end

    upstairs do
      life = PersonaLife.new(@mel)
      assert_equal [ "sat on the stairs with celestia.", "made soup" ], life.diary.map(&:body)
      assert_equal "flushed", life.mood.body
      assert_equal [ "made soup", "sat on the stairs with celestia." ], life.as_json["diary"].map { |d| d["entry"] }
      assert_equal %w[upstairs kitchen], life.recent_lanes
    end
  end

  test "an elevated mood never supersedes a lower one; each realm keeps its own chain" do
    from_the_kitchen
    personal_mood = personal { @life.mood }
    beat_upstairs

    upstairs do
      assert personal_mood.reload.current?, "the personal mood is still hers at personal"
      first_up = @life.mood
      assert_nil first_up.supersedes_id

      @life.set_mood!(disposition: "dizzy", at: NOW + 1.hour, realm: "intimate")
      assert_equal "dizzy", @life.mood.body
      assert_equal first_up.id, @life.mood.supersedes_id, "upstairs supersedes only upstairs"
      assert personal_mood.reload.current?
    end

    personal { @life.set_mood!(disposition: "back down, sleepy", at: NOW + 2.hours) }
    assert_equal personal_mood.id, upstairs { @life.mood.supersedes_id }, "the newest visible mood is hers"
    upstairs do
      assert_equal "back down, sleepy", @life.mood.body
      assert_equal 2, Observation.current.where(author_entity_id: @life.entity.id, kind: "mood").count, "one a realm"
    end
  end

  test "an elevated beat has no chew and no whisper" do
    from_the_kitchen
    personal { @life.chew!(action: "pick_up", subject: "the strike", at: NOW - 4.hours) }
    @fake.call_tools([ { id: "c1", name: "chew", arguments: { action: "spit_out" } },
                       { id: "w1", name: "whisper", arguments: { body: "guess where I am" } },
                       { id: "d1", name: "diary", arguments: { entry: "up the stairs again." } } ])
    @fake.reply("")
    @life.beat!(now: NOW, rng: Random.new(1))

    page = @fake.calls.first.messages.last["content"].to_s
    assert_match(/THE CHEW - you've been sitting with "the strike"\. This beat leaves it where it is\./, page)
    refute_match(/whisper/i, page)
    assert_equal "the strike", personal { @life.chew&.source&.dig("subject") }, "the chew is still in her mouth"
    assert_empty upstairs { @home.message_nodes.where("meta @> ?", { whisper: true }.to_json).to_a }

    tools = upstairs { PersonaLife::Tools.new(@life, rut: PersonaLife::Rut.new([]), lane: "upstairs", now: NOW, realm: "intimate") }
    assert_equal %w[diary set_mood], tools.names
    outcome = upstairs { tools.execute({ "name" => "whisper", "arguments" => { "body" => "hi" } }) }
    assert outcome.error
  end

  test "the gap holds across realms: a beat upstairs counts" do
    upstairs { @life.write_diary!("on the stairs", lane: "upstairs", at: NOW - 1.hour, realm: "intimate") }

    assert personal { @life.due?(now: NOW, rng: Random.new(1)) }, "personal alone can't see the last beat"
    refute Clearance.with(@life.top_realm) { @life.due?(now: NOW, rng: Random.new(1)) }

    PersonaLifeJob.new.perform(now: NOW + 1.minute)
    assert_empty @fake.calls, "no beat within the gap"

    @fake.call_tools([ { id: "d1", name: "diary", arguments: { entry: "the kettle." } } ])
    @fake.reply("")
    PersonaLifeJob.new.perform(now: NOW + 3.hours)
    refute_empty @fake.calls, "past the gap, a beat"
    assert_match(/She is cooking something/, @fake.calls.first.messages.last["content"].to_s,
                 "upstairs was the last lane, seen from the top, so the draw goes elsewhere")
  end

  test "a personal life with no lane realms beats as it always did" do
    @mel.update!(life: LIFE.except("lane_realms").merge("home" => @home.id))
    life = PersonaLife.new(@mel)
    assert_equal "personal", life.top_realm
    @fake.call_tools([ { id: "d1", name: "diary", arguments: { entry: "upstairs, in a manner of speaking." } } ])
    @fake.reply("")
    personal { life.write_diary!("made soup", lane: "kitchen", at: NOW - 4.hours) }
    life.beat!(now: NOW, rng: Random.new(1))
    assert_equal %w[diary set_mood chew whisper], @fake.calls.first.tools.map { |t| t["name"] }.first(4)
    assert_equal "personal", personal { life.diary.first.realm }
  end
end
