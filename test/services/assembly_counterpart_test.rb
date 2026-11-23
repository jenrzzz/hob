require "test_helper"

# Who a persona is talking to, apart from who she is (Assembly::Counterpart).
class AssemblyCounterpartTest < ActiveSupport::TestCase
  RELATIONS = { "principal:tester" => "Tester is her oldest friend.", "*" => "Not Tester. Be yourself; keep his things his." }.freeze

  setup do
    @robyn = Persona.create!(key: "robyn", name: "Robyn",
                             prompt: { "system_core" => "You are Robyn.", "relations" => RELATIONS })
  end

  def turn(convo = conversation, **opts)
    @fake.reply("rar")
    ChatTurn.new(conversation: convo, branch: convo.branch, content: "hi", persona: @robyn, **opts).call
    @fake.calls.last
  end

  test "the key's own principal is who she is talking to, and their relation follows who she is" do
    system = turn.system
    assert_operator system.index("You are Robyn."), :<, system.index("## Who you are talking to")
    assert_includes system, "tester: a person of the household."
    assert_includes system, "Tester is her oldest friend."
    refute_includes system, "Not Tester."
  end

  test "a person's key may name someone else: a principal, a persona, or a guest" do
    agent("skipsy")
    persona("saffron")

    system = turn(with: "principal:skipsy").system
    assert_includes system, "skipsy: an agent."
    assert_includes system, "Not Tester."
    refute_includes system, "oldest friend"

    assert_includes turn(with: "persona:saffron").system, "Saffron: another persona."

    system = turn(with: { "name" => "Claude", "about" => "works on her house" }).system
    assert_includes system, "Claude: a guest hob does not know"
    assert_includes system, "says about them: works on her house"
    assert_includes system, "Not Tester."

    stage = PromptSnapshot.order(:created_at).last.assembled["stages"].find { |s| s["name"] == "counterpart" }
    assert_equal "guest:claude", stage["with"]
  end

  test "only a person's key names someone, and only someone who is there" do
    assert_raises(Gateway::Invalid) { turn(with: "principal:nobody") }
    assert_raises(Gateway::Invalid) { turn(with: "persona:nobody") }
    assert_raises(Gateway::Invalid) { turn(with: "somebody") }
    assert_raises(Gateway::Invalid) { turn(with: { "name" => "" }) }
    assert_raises(Gateway::Invalid) { turn(with: { "name" => "x", "kind" => "human" }) }

    skipsy, = agent("skipsy")
    Current.principal = skipsy
    assert_raises(Gateway::Invalid) { turn(with: "principal:tester") }
  end

  test "a persona with no relations, or a turn with nobody on the other end, says nothing" do
    plain = persona("plain")
    convo = conversation
    @fake.reply("ok")
    ChatTurn.new(conversation: convo, branch: convo.branch, content: "hi", persona: plain).call
    refute_includes @fake.calls.last.system, "Who you are talking to"

    Current.principal = nil
    refute_includes turn.system, "Who you are talking to"
  end

  test "someone with no entry and no entry for anyone is still named" do
    @robyn.update!(prompt: @robyn.prompt.merge("relations" => RELATIONS.except("*")))
    system = turn(with: { "name" => "Claude" }).system
    assert_includes system, "Claude: a guest"
    refute_includes system, "oldest friend"
  end

  test "relations that do not read are refused" do
    bad = Persona.new(key: "bad", name: "Bad", prompt: { "system_core" => "x", "relations" => { "jenner" => "text" } })
    refute bad.valid?
    bad.prompt = { "system_core" => "x", "relations" => { "principal:jenner" => "" } }
    refute bad.valid?
    bad.prompt = { "system_core" => "x", "relations" => [ "nope" ] }
    refute bad.valid?
  end

  test "a corpus kept for some parties is not offered to anyone else" do
    Records.create_collection({ "name" => "archive", "key" => "chunk", "description" => "DM chunks", "realm" => "personal" }, owner: @principal)
    @robyn.update!(tools: { "corpora" => [ { "tool" => "recall_archive", "collection" => "archive", "with" => [ "principal:tester" ] },
                                           { "tool" => "find_recipe", "collection" => "archive" } ] })

    names = ->(call) { Array(call.tools).map { |t| t["name"] } }
    assert_includes names.(turn), "recall_archive"

    theirs = names.(turn(with: { "name" => "Claude" }))
    refute_includes theirs, "recall_archive"
    assert_includes theirs, "find_recipe"

    # Her alone (a beat of her life): nobody to keep it from.
    alone = CorpusTools.build(personas: [ @robyn ], conversation: conversation, counterpart: nil)
    assert_includes alone.names, "recall_archive"

    @robyn.tools = { "corpora" => [ { "tool" => "recall_archive", "collection" => "archive", "with" => "tester" } ] }
    refute @robyn.valid?
  end
end
