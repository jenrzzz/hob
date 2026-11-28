require "test_helper"

# A dose (MEMORY.md, "A dose"): a persona's recall warped for a while, on a
# curve, by a tool she is offered.
class DoseTest < ActiveSupport::TestCase
  TOOLS = { "dose" => true,
            "corpora" => [ { "tool" => "recall_archive", "collection" => "archive" } ] }.freeze
  T0 = Time.utc(2026, 11, 28, 21, 0)
  # Nearest to "cat kitten purring whiskers" first: each shares one word fewer.
  ARCHIVE = { "near" => "cat kitten purring whiskers", "next" => "cat kitten purring rug", "out" => "cat kitten persian rug",
              "far" => "cat persian rug weaving", "gone" => "tidal locking of moons" }.freeze

  setup do
    ModelRole.create!(role: "embedding", chain: [ { "provider" => "backup", "model" => "embed-test" } ])
    @archive = Records.create_collection(
      { "name" => "archive", "key" => "chunk", "description" => "DM chunks", "realm" => "personal", "embed" => "text" },
      owner: @principal
    )
    Records.put_many({ "collection" => "archive", "records" => ARCHIVE.map { |key, text|
      { "data" => { "chunk" => key, "text" => text }, "observed_at" => "2021-03-02T05:00:00Z" }
    } }, by: Records::Writer.new(principal: @principal, surface: "import"))
    @robyn = persona("robyn")
    @robyn.update!(tools: TOOLS)
  end

  def keys(warp)
    Records::Search.search(@archive, query: "cat kitten purring whiskers", limit: 5, warp: warp).map { |h| h.record.key }
  end

  test "it comes on, holds, tapers and is gone" do
    dose = Dose.take!(@robyn, level: "high", minutes: 100, now: T0)
    at = ->(minutes) { dose.warp(T0 + minutes.minutes) }

    assert_equal 0.0, at.(0)
    assert_operator at.(5), :<, at.(10)
    assert_operator at.(10), :<, at.(19)
    assert_equal 0.85, at.(20)
    assert_equal 0.85, at.(54)
    assert_operator at.(70), :<, 0.85
    assert_operator at.(95), :<, at.(70)
    assert_equal 0.0, at.(100)

    assert_equal 0.3, Dose.take!(@robyn, level: "low", minutes: 100, now: T0).warp(T0 + 30.minutes)
    travel_to(T0 + 30.minutes) { assert_equal 0.3, Dose.warp(@robyn.reload) }
    travel_to(T0 + 2.hours) { assert_nil Dose.of(@robyn) }
  end

  test "a warped search overshoots the nearest, further the more it is warped, and returns what is there" do
    assert_equal "near", keys(0.0).first
    assert_equal keys(0.0), keys(0.0)

    assert_equal "next", keys(0.3).first, "low: adjacent"
    assert_includes keys(0.3), "near", "its words still find it, further down"
    assert_equal "far", keys(0.85).first, "high: far"
    assert_equal "gone", keys(1.0).first, "all the way out"

    hit = Records::Search.search(@archive, query: "cat kitten purring whiskers", limit: 1, warp: 1.0).first
    assert_equal ARCHIVE["gone"], hit.record.data["text"], "verbatim, as kept"
  end

  test "memory's recall is warped the same way, and its words hold less" do
    velvet = persona("velvet")
    author = velvet.memory_entity
    notes = ARCHIVE.transform_values { |text| Memory.remember!(about: author, body: text, realm: "personal", author: author) }
    recalled = ->(warp) { Memory.recall(query: "cat kitten purring whiskers", author: author, scope: "mine", warp: warp).first.observation }

    assert_equal notes["near"], recalled.(0.0)
    assert_equal notes["gone"], recalled.(1.0)
  end

  test "she takes one with the tool, and her archive answers differently while it runs" do
    convo = conversation(realm: "personal")
    ask = lambda do
      @fake.call_tools([ { id: "a#{rand(9999)}", name: "recall_archive", arguments: { query: "cat kitten purring whiskers", limit: 1 } } ])
      @fake.reply("mm")
      result = ChatTurn.new(conversation: convo, branch: convo.branch, persona: @robyn.reload, content: "the cat?").call
      [ JSON.parse(result.native.first["content"])["records"].first["key"], result ]
    end

    travel_to(T0) do
      assert_equal "near", ask.().first
      @fake.call_tools([ { id: "d1", name: "dose", arguments: { level: "high", minutes: 60 } } ])
      @fake.reply("oh")
      result = ChatTurn.new(conversation: convo, branch: convo.branch, persona: @robyn, content: "go on then").call
      assert_includes @fake.calls.last.tools.map { |t| t["name"] }, "dose"
      taken = JSON.parse(result.native.first["content"])
      assert_equal "high", taken["taken"]
      assert_equal (T0 + 1.hour).iso8601, taken["wears_off_at"]
      assert_equal "near", ask.().first, "nothing yet"
    end

    travel_to(T0 + 20.minutes) do
      key, result = ask.()
      assert_not_equal "near", key
      assert_no_match(/dose|warp/, result.native.first["content"], "a result does not say")
      stage = PromptSnapshot.find_by!(digest: result.snapshot).assembled["stages"].find { |s| s["name"] == "dose" }
      assert_equal "high", stage["level"]
      assert_match(/You took a high dose 20 min ago/, @fake.calls.last.messages.to_json)
    end

    travel_to(T0 + 61.minutes) do
      key, result = ask.()
      assert_equal "near", key
      assert_nil PromptSnapshot.find_by!(digest: result.snapshot).assembled["stages"].find { |s| s["name"] == "dose" }
    end
  end

  test "level none ends one early; a bad dose is an error she reads" do
    convo = conversation(realm: "personal")
    call = lambda do |arguments|
      @fake.call_tools([ { id: "d#{rand(9999)}", name: "dose", arguments: arguments } ])
      @fake.reply("ok")
      ChatTurn.new(conversation: convo, branch: convo.branch, persona: @robyn, content: "well").call.native.first
    end

    assert_match(/level is low, medium, high or none/, call.({ level: "heroic" })["content"])
    assert_match(/minutes is 10 to 360/, call.({ level: "low", minutes: 5000 })["content"])
    assert_not call.({ level: "medium" })["error"]
    assert_equal 90, @robyn.reload.dose["minutes"]
    assert_equal "medium", JSON.parse(call.({ level: "none" })["content"])["ended"]
    assert_equal({}, @robyn.reload.dose)
    assert_nil JSON.parse(call.({ level: "none" })["content"])["ended"]
  end

  test "only a persona offered one has the tool, and turning it off ends a dose" do
    Dose.take!(@robyn, level: "high", minutes: 60, now: T0)
    travel_to(T0 + 20.minutes) do
      assert_operator Dose.warp(@robyn), :>, 0
      @robyn.update!(tools: TOOLS.except("dose"))
      assert_equal 0.0, Dose.warp(@robyn)

      convo = conversation(realm: "personal")
      @fake.reply("hi")
      ChatTurn.new(conversation: convo, branch: convo.branch, persona: @robyn, content: "hi").call
      assert_equal [ "recall_archive" ], @fake.calls.last.tools.map { |t| t["name"] }
    end

    assert_not @robyn.update(tools: { "dose" => "yes" })
    assert_not @robyn.update(tools: { "dose" => true, "corpora" => [ { "tool" => "dose", "collection" => "archive" } ] })
  end
end
