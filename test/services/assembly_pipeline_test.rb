require "test_helper"

class AssemblyPipelineTest < ActiveSupport::TestCase
  def assemble(**opts)
    convo = opts.delete(:conversation) || conversation
    Assembly::Pipeline.new(conversation: convo, head: opts.delete(:head), **opts).assemble
  end

  test "context blocks render stable first, volatile last, and honour budgets" do
    result = assemble(context: [
      { "name" => "recent", "body" => "r" * 100, "volatile" => true },
      { "name" => "recipe", "body" => { "title" => "Soup" } },
      { "name" => "plan", "body" => "p" * 400, "budget" => 10 }
    ])

    system = result.system
    assert_operator system.index("### recipe"), :<, system.index("### plan")
    assert_operator system.index("### plan"), :<, system.index("### recent")
    assert_includes system, '"title": "Soup"'
    assert_includes system, "[truncated]"

    stage = result.snapshot.assembled["stages"].find { |s| s["name"] == "scenario" }
    assert_equal %w[recipe plan recent], stage["blocks"].map { |b| b["name"] }
    assert_equal [ false, true, false ], stage["blocks"].map { |b| b["truncated"] }
    assert_equal [ false, false, true ], stage["blocks"].map { |b| b["volatile"] }
  end

  test "a bare string or hash context still works" do
    assert_equal "## Context\n\non screen", assemble(context: "on screen").system
    assert_includes assemble(context: { "recipe" => "Soup" }).system, "\"recipe\": \"Soup\""
    assert_nil assemble(context: nil).snapshot.assembled["stages"].find { |s| s["name"] == "scenario" }
  end

  test "the stage budget drops volatile blocks first" do
    preset = Preset.create!(key: "tight", name: "Tight", stages: [ { "name" => "scenario", "enabled" => true, "budget" => 30 } ])
    result = assemble(preset: preset, context: [
      { "name" => "hot", "body" => "h" * 100, "volatile" => true },
      { "name" => "stable", "body" => "s" * 80 }
    ])
    assert_includes result.system, "### stable"
    refute_includes result.system, "### hot"
  end

  test "the instruction stage is a trailing user message, from the request or the persona" do
    interviewer = persona("interviewer", instruction: "Ask the next question.")
    convo = conversation
    q = MessageNode.append!(conversation: convo, parent_hash: MessageNode::ROOT, role: "assistant", content: "Q1?")
    a = MessageNode.append!(conversation: convo, parent_hash: q.content_hash, role: "user", content: "A1.")

    result = assemble(conversation: convo, head: a, personas: [ interviewer ])
    assert_equal %w[assistant user user], result.messages.map { |m| m["role"] }
    assert_equal "Ask the next question.", result.messages.last["content"]

    result = assemble(conversation: convo, head: a, personas: [ interviewer ], instruction: "The writer is STUCK.")
    assert_equal "The writer is STUCK.", result.messages.last["content"]
    assert_equal "instruction", result.snapshot.assembled["stages"].last["name"]
  end

  test "an ensemble persona stage voices every speaker and tags history" do
    saffron = persona("saffron", system_core: "You are Saffron, precise.")
    maggie = persona("maggie", system_core: "You are Maggie, warm.")
    convo = conversation
    u = MessageNode.append!(conversation: convo, parent_hash: MessageNode::ROOT, role: "user", content: "dinner?")
    s = MessageNode.append!(conversation: convo, parent_hash: u.content_hash, role: "assistant", speaker: "saffron", content: "Soup.")

    result = assemble(conversation: convo, head: s, personas: [ saffron, maggie ])
    assert_includes result.system, "ensemble of 2 speakers"
    assert_includes result.system, "## [saffron] Saffron\n\nYou are Saffron, precise."
    assert_includes result.system, "## [maggie] Maggie"
    assert_equal "[saffron]\nSoup.", result.messages.last["content"]
    assert_equal %w[saffron maggie], result.snapshot.assembled["stages"].first["persona"]

    single = assemble(conversation: convo, head: s, personas: [ saffron ])
    assert_equal "You are Saffron, precise.", single.system
    assert_equal "Soup.", single.messages.last["content"], "a single speaker is never tagged"
  end

  test "event nodes stay out of the prompt" do
    convo = conversation
    u = MessageNode.append!(conversation: convo, parent_hash: MessageNode::ROOT, role: "user", content: "add soup")
    e = MessageNode.append!(conversation: convo, parent_hash: u.content_hash, role: "event", kind: "event", content: "Added Soup to the plan")
    result = assemble(conversation: convo, head: e)
    assert_equal [ "add soup" ], result.messages.map { |m| m["content"] }
  end

  test "situation is volatile trailing context, snapshotted after history and before instruction" do
    writer = Situation::Writer.new(principal: @principal, surface: "app:Test iPhone", clearance: "intimate")
    Situation.observe(person: @principal, observations: [
      { "kind" => "location", "value" => { "place" => "home" } },
      { "kind" => "company", "value" => { "with" => [ "kids" ] } },
      { "kind" => "topic", "slot" => "permit", "value" => { "text" => "the ADU permit" }, "realm" => "personal" }
    ], by: writer)
    convo = conversation(realm: "household")
    user = MessageNode.append!(conversation: convo, parent_hash: MessageNode::ROOT, role: "user", content: "What now?")

    result = assemble(conversation: convo, head: user, instruction: "Keep it short.")
    assert_equal %w[user user user], result.messages.map { |message| message["role"] }
    assert_equal "What now?", result.messages.first["content"]
    assert_includes result.messages.second["content"], "[Situation: tester"
    assert_includes result.messages.second["content"], "company: with kids"
    assert_includes result.messages.second["content"], "topic (tester"
    assert_equal "Keep it short.", result.messages.last["content"]
    assert_equal %w[history situation instruction], result.snapshot.assembled["stages"].last(3).map { |stage| stage["name"] }
    assert_equal %w[household personal], result.snapshot.assembled["stages"].find { |stage| stage["name"] == "situation" }["realms"].sort
    assert_equal "personal", convo.reload.taint_realm
  end

  test "a turn can opt out of situation or select another household person" do
    tessa = Principal.create!(name: "tessa", kind: "human", max_clearance: "household")
    writer = Situation::Writer.new(principal: tessa, surface: "shortcuts", clearance: "household")
    Situation.observe(person: tessa, observations: [ { "kind" => "location", "value" => { "place" => "home" } } ], by: writer)
    convo = conversation
    user = MessageNode.append!(conversation: convo, parent_hash: MessageNode::ROOT, role: "user", content: "Dinner?")

    selected = assemble(conversation: convo, head: user, situation: { person: "tessa" })
    assert_includes selected.messages.last["content"], "Situation: tessa"
    assert_includes selected.messages.last["content"], "location: home"

    opted_out = assemble(conversation: convo, head: user, situation: false)
    assert_equal [ "Dinner?" ], opted_out.messages.map { |message| message["content"] }
    assert_nil opted_out.snapshot.assembled["stages"].find { |stage| stage["name"] == "situation" }
  end
end
