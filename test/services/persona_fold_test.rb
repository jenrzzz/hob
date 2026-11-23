require "test_helper"

# The fold (MELUZINA.md, "The fold"): what she keeps of her home conversation
# once a stretch of it has left living presence.
class PersonaFoldTest < ActiveSupport::TestCase
  LIFE = {
    "instruction" => "Write the next beat of her life.", "realm" => "personal", "zone" => "America/Chicago",
    "odds" => { "0-23" => 0.0 }, "min_gap_minutes" => 180, "dial" => "off",
    "fold" => { "instruction" => "THE FOLD. Keep what mattered, in your own words.", "about" => "principal:tester", "quiet_hours" => 6 }
  }.freeze
  T0 = Time.utc(2026, 11, 22, 6, 0)

  setup do
    @home = conversation(realm: "intimate")
    @mel = persona("mel")
    @mel.update!(life: LIFE.merge("home" => @home.id))
    @him = Entity.for_principal(@principal)
  end

  def fold(now)
    PersonaLife::Fold.new(PersonaLife.new(@mel.reload), now: now)
  end

  def say(role, text, at:, meta: {})
    branch = @home.branch
    node = MessageNode.append!(conversation: @home, parent_hash: branch.head_hash, role: role, content: text, meta: meta)
    node.update_columns(created_at: at)
    branch.advance!(node)
    node
  end

  def answer(kept, stand)
    @fake.reply(JSON.generate("kept" => kept, "where_things_stand" => stand))
  end

  def hers(kind)
    Clearance.with("intimate") { Observation.where(author_entity_id: @mel.memory_entity.id, kind: kind).order(:created_at).to_a }
  end

  test "a visit that has gone quiet is folded into memories she authors, at the home's realm" do
    say("user", "i gave the shed a back door", at: T0)
    say("assistant", "oh no. where does it go", at: T0 + 1.minute)
    last = say("user", "somewhere with ozone. goodnight", at: T0 + 2.minutes)

    refute fold(T0 + 3.hours).due?, "the visit may not be over"
    assert fold(T0 + 7.hours).due?

    answer([ "he gave the shed a back door. it goes somewhere with ozone." ], "the shed has a door and i don't know where it goes yet.")
    result = fold(T0 + 7.hours).run!
    assert_equal [ 3, 1 ], [ result.nodes, result.kept.size ]

    call = @fake.calls.last
    assert_includes call.system, "You are mel."
    assert_includes call.system, "THE FOLD."
    page = call.messages.last["content"]
    assert_match(/\[nov 22, 12:00am\] him: i gave the shed a back door/, page)
    assert_match(/\] you: oh no\. where does it go/, page)
    assert_empty Array(call.tools), "no tools: she answers in the shape asked"
    assert_equal false, PersonaLife::Fold::SCHEMA["additionalProperties"], "a provider refuses the schema without it"

    kept = hers("kept").sole
    assert_equal "he gave the shed a back door. it goes somewhere with ozone.", kept.body
    assert_equal [ "intimate", @him.id, @home.id, last.content_hash ], [ kept.realm, kept.entity_id, kept.conversation_id, kept.node_hash ]
    assert_equal({ "via" => "fold" }, kept.source)
    assert_equal last.created_at.to_i, kept.observed_at.to_i
    assert_equal "the shed has a door and i don't know where it goes yet.", hers("where_things_stand").sole.body

    refute fold(T0 + 8.hours).due?, "nothing new since the bookmark"
    assert_equal 0, Clearance.with("personal") { Observation.where(kind: "kept").count }, "out of sight below the home's realm"
  end

  test "the next fold starts after the last, knows what is already kept, and replaces where things stand" do
    say("user", "first night", at: T0)
    answer([ "the first night happened." ], "we left it at the first night.")
    fold(T0 + 7.hours).run!
    Clearance.with("intimate") do
      Memory.remember!(about: @him, body: "he said the hall should smell of creosote", realm: "intimate", author: @mel.memory_entity)
    end

    say("assistant", "rar =^.^=", at: T0 + 20.hours, meta: { "whisper" => true })
    say("user", "second night", at: T0 + 21.hours)
    answer([], "")
    result = fold(T0 + 30.hours).run!
    page = @fake.calls.last.messages.last["content"]
    refute_match(/first night\n|him: first night/, page.split("THE STRETCH").last, "already folded")
    assert_match(/you \(a whisper, unprompted\): rar/, page)
    assert_match(/ALREADY IN YOUR MEMORY.*the first night happened\..*creosote/m, page)
    assert_match(/WHERE THINGS STOOD.*we left it at the first night\./m, page)

    assert_empty result.kept, "a quiet stretch may keep nothing"
    stands = hers("where_things_stand")
    assert_equal [ "superseded", "current" ], stands.map(&:status)
    assert_equal "we left it at the first night.", stands.last.body, "nothing new said: the old one carries, and moves the bookmark"
    refute fold(T0 + 31.hours).due?
  end

  test "a visit that outgrows the window folds its oldest part and leaves the recent part live" do
    40.times { |i| say(i.even? ? "user" : "assistant", "line #{i} " + ("word " * 195), at: T0 + i.minutes) }
    refute fold(T0 + 45.minutes).due?, "40,000 characters: still inside what she can see, more or less"

    20.times { |i| say(i.even? ? "user" : "assistant", "line #{40 + i} " + ("word " * 195), at: T0 + (40 + i).minutes) }
    now = T0 + 65.minutes
    stretch = Clearance.with("intimate") { fold(now).stretch }
    assert_match(/\Aline 0 /, stretch.first.content)
    live = 60 - stretch.size
    assert_includes 30..33, live, "about a window's worth (32,000 characters) is left live"

    answer([ "a very long night of words." ], "still going.")
    fold(now).run!
    refute fold(now).due?, "what is left fits the window and the visit is not over"
    assert fold(now + 7.hours).due?, "until it is"
  end

  test "an answer in the wrong shape keeps nothing and leaves the stretch for later" do
    say("user", "hello", at: T0)
    2.times { @fake.reply("not json at all") }
    assert_nil fold(T0 + 7.hours).run!
    assert_empty hers("kept") + hers("where_things_stand")
    assert Clearance.with("intimate") { fold(T0 + 8.hours).stretch.any? }
  end

  test "the job folds on the hour, beside the beat, and a persona with no fold is left alone" do
    say("user", "hello", at: T0)
    answer([ "he said hello." ], "hello was said.")
    PersonaLifeJob.new.perform(now: T0 + 7.hours + 20.minutes)
    assert_empty hers("kept"), "not this tick"
    PersonaLifeJob.new.perform(now: T0 + 8.hours)
    assert_equal [ "he said hello." ], hers("kept").map(&:body)

    @mel.update!(life: LIFE.except("fold").merge("home" => @home.id))
    say("user", "again", at: T0 + 9.hours)
    refute fold(T0 + 20.hours).due?
  end

  test "a fold config is checked" do
    @mel.life = LIFE.merge("fold" => { "about" => "principal:tester" })
    refute @mel.valid?
    @mel.life = LIFE.merge("fold" => LIFE["fold"].merge("about" => "jenner"))
    refute @mel.valid?
    @mel.life = LIFE.merge("fold" => LIFE["fold"].merge("quiet_hours" => 0))
    refute @mel.valid?
    @mel.life = LIFE.merge("fold" => LIFE["fold"].merge("every" => 3))
    refute @mel.valid?
  end
end
