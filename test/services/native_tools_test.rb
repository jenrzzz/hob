require "test_helper"

# The native tool venue (MEMORY.md, "Native tools"): recall and remember run
# inside the turn; the caller's tools are still handed back.
class NativeToolsTest < ActiveSupport::TestCase
  CLIENT = [ { "name" => "show_image", "description" => "Show an image", "input_schema" => { "type" => "object" } },
             { "name" => "stage_scene", "description" => "Stage a scene", "input_schema" => { "type" => "object" } } ].freeze

  setup do
    @velvet = persona("velvet")
    @jenner = Entity.for_principal(@principal)
    @noted = Memory.remember!(about: @jenner, body: "He lingers on lace.", realm: "intimate", author: @velvet.memory_entity)
  end

  def turn(convo, **opts)
    ChatTurn.new(conversation: convo, branch: convo.branch, persona: @velvet, **opts)
  end

  def kinds(convo)
    convo.branch.reload.timeline.map { |n| n.kind == "text" ? n.role : n.kind }
  end

  test "memory is off unless asked for; the persona or the request turns it on" do
    convo = conversation(realm: "intimate")
    @fake.reply("Hi.")
    turn(convo, content: "hello").call
    assert_empty @fake.calls.last.tools
    refute_match "What you remember", @fake.calls.last.system

    @velvet.update!(memory: { "recall" => true })
    @fake.reply("Hi.")
    turn(convo, content: "lace?").call
    assert_match(/What you remember.*He lingers on lace\./m, @fake.calls.last.system)
    assert_empty @fake.calls.last.tools, "recall alone offers no tools"

    @fake.reply("Hi.")
    turn(convo, content: "lace?", memory: false).call
    refute_match "What you remember", @fake.calls.last.system
  end

  test "a round of only native calls loops server-side and ends in text" do
    convo = conversation(realm: "intimate")
    @fake.call_tools([ { id: "n1", name: "recall", arguments: { query: "lace" } } ])
    @fake.reply("You like lace.")
    seen = []
    t = turn(convo, content: "what do I like?", memory: { tools: true })
    t.on_native = ->(kind, payload) { seen << [ kind, payload["name"] ] }
    result = t.call

    assert_equal "success", result.status
    assert_equal "You like lace.", result.assistant_node.content
    assert_equal 2, result.rounds
    assert_equal [ [ :call, "recall" ], [ :result, "recall" ] ], seen
    assert_equal %w[user tool_call tool_result assistant], kinds(convo)
    recalled = JSON.parse(result.native.first["content"])
    assert_equal [ @noted.id ], recalled["observations"].map { |o| o["id"] }
    assert recalled["observations"].first["yours"]
    second = @fake.calls.last
    assert_equal %w[user assistant tool], second.messages.map { |m| m["role"] }
    assert_includes second.tools.map { |t2| t2["name"] }, "remember"
    assert_equal 20, result.units["input_tokens"], "usage sums the rounds"
    assert_equal "native", convo.branch.timeline.find(&:tool_result?).meta["venue"]
    assert_kind_of Integer, convo.branch.timeline.find(&:tool_result?).meta["duration_ms"], "native runs are timed for the audit"
  end

  test "a round mixing native and client calls answers the native ones and hands back the rest" do
    convo = conversation(realm: "intimate")
    @fake.call_tools([ { id: "n1", name: "recall", arguments: { query: "lace" } },
                       { id: "c1", name: "show_image", arguments: { id: 30880 } },
                       { id: "c2", name: "stage_scene", arguments: { scene: "slow" } } ], content: "Let me see.")
    first = turn(convo, content: "show me", tools: CLIENT, memory: true).call

    assert_equal "tool_calls", first.status
    assert_equal %w[c1 c2], first.tool_calls.map { |c| c["id"] }
    assert_equal [ "recall" ], first.native.map { |n| n["name"] }
    assert_equal %w[user assistant tool_call tool_call tool_call tool_result], kinds(convo)
    assert_equal %w[c1 c2], ToolExchange.pending_calls(convo.branch.reload.head).map { |c| c["id"] }

    assert_raises(Gateway::Invalid) do
      turn(convo, tools: CLIENT, memory: true, tool_results: [ { "id" => "n1", "content" => "x" }, { "id" => "c1", "content" => "x" } ]).call
    end

    @fake.reply("There.")
    second = turn(convo, tools: CLIENT, memory: true,
                  tool_results: [ { "id" => "c1", "content" => "shown" }, { "id" => "c2", "content" => "staged" } ]).call
    assert_equal "success", second.status
    messages = @fake.calls.last.messages
    assert_equal %w[user assistant tool tool tool], messages.map { |m| m["role"] }
    assert_equal %w[n1 c1 c2], messages[1]["tool_calls"].map { |c| c["id"] }
    assert_equal %w[n1 c1 c2], messages[2..].map { |m| m["tool_call_id"] }
  end

  test "remember writes at the conversation's taint, capped by the clearance, with provenance" do
    convo = conversation(realm: "personal")
    convo.taint!("intimate")
    @fake.call_tools([ { id: "n1", name: "remember", arguments: { body: "He wanted it slower tonight.", kind: "preference" } } ])
    @fake.reply("Noted.")
    turn(convo, content: "slower", memory: { tools: true }).call
    kept = Observation.order(:created_at).last
    assert_equal [ "intimate", @jenner, @velvet.memory_entity, convo.id ], [ kept.realm, kept.entity, kept.author_entity, kept.conversation_id ]
    assert_equal convo.branch.timeline.find(&:tool_call?).content_hash, kept.node_hash

    as(@principal, realm: "personal") do
      @fake.call_tools([ { id: "n2", name: "remember", arguments: { body: "Asked about dinner." } } ])
      @fake.reply("Ok.")
      turn(convo, content: "dinner", memory: { tools: true }).call
      assert_equal "personal", Observation.order(:created_at).last.realm
    end
  end

  test "recall inside a conversation never reads above the conversation's realm" do
    convo = conversation(realm: "personal")
    plain = Memory.remember!(about: @jenner, body: "He likes lace curtains.", realm: "personal", author: @velvet.memory_entity)
    @fake.call_tools([ { id: "n1", name: "recall", arguments: { query: "lace" } } ])
    @fake.reply("Curtains.")
    result = turn(convo, content: "lace?", memory: true).call
    ids = JSON.parse(result.native.first["content"])["observations"].map { |o| o["id"] }
    assert_equal [ plain.id ], ids
    refute_match "He lingers on lace", @fake.calls.last.system
    refute_includes convo.message_nodes.map(&:content).join, "He lingers on lace"
  end

  test "a bad native call is an error result the model reads" do
    convo = conversation(realm: "intimate")
    @fake.call_tools([ { id: "n1", name: "remember", arguments: { body: "" } } ])
    @fake.reply("Sorry.")
    result = turn(convo, content: "x", memory: { tools: true }).call
    assert result.native.first["error"]
    assert_equal true, @fake.calls.last.messages.last["error"]
  end

  test "the cap holds for a model that keeps recalling" do
    convo = conversation(realm: "intimate")
    2.times { |i| @fake.call_tools([ { id: "n#{i}", name: "recall", arguments: { query: "lace" } } ]) }
    @fake.reply("Enough.")
    result = turn(convo, content: "x", memory: { tools: true }, max_iterations: 2).call
    assert_equal "Enough.", result.assistant_node.content
    assert_equal "none", @fake.calls.last.tool_choice
  end

  test "a caller's tool may not take a native name, and memory needs one persona" do
    convo = conversation(realm: "intimate")
    assert_raises(Gateway::Invalid) { turn(convo, content: "x", memory: true, tools: [ { "name" => "recall" } ]).call }
    assert_raises(Gateway::Invalid) do
      ChatTurn.new(conversation: convo, branch: convo.branch, personas: [ @velvet, persona("other") ], content: "x", memory: true).call
    end
  end

  test "a completion with a persona's memory tools loops natively too" do
    @fake.call_tools([ { id: "n1", name: "recall", arguments: { query: "lace" } } ])
    @fake.reply("Lace.")
    result = Completion.new(role: "chat-default", persona: @velvet, messages: [ user_message("what do I like?") ],
                            realm: "intimate", memory: { tools: true }).call
    assert_equal "success", result.status
    assert_equal "Lace.", result.response.content
    assert_equal [ "recall" ], result.native.map { |n| n["name"] }
  end

  test "a persona whose memory is her own recalls only what she authored" do
    other = persona("presence")
    Memory.remember!(about: @jenner, body: "He lingers on lace, says the presence.", realm: "intimate", author: other.memory_entity)
    Memory.deposit!([ { "about" => "principal:tester", "body" => "Lace, by evidence.", "kind" => "evidence" } ], realm: "intimate")
    convo = conversation(realm: "intimate")

    @velvet.update!(memory: { "recall" => true, "tools" => true })
    @fake.reply("Hi.")
    turn(convo, content: "lace?").call
    assert_match(/says the presence/, @fake.calls.last.system, "shared by default")

    @velvet.update!(memory: { "recall" => true, "tools" => true, "own" => true })
    @fake.reply("Hi.")
    turn(convo, content: "lace?").call
    assert_match(/He lingers on lace\./, @fake.calls.last.system)
    refute_match(/says the presence|by evidence/, @fake.calls.last.system)

    @fake.call_tools([ { id: "o1", name: "recall", arguments: { query: "lace", scope: "all" } } ])
    @fake.reply("Lace.")
    result = turn(convo, content: "what do I like?").call
    assert_equal [ @noted.id ], JSON.parse(result.native.first["content"])["observations"].map { |o| o["id"] },
                 "asking for all does not widen her own memory"
  end

  # Keeping her notes fresh: a note is never edited, so a correction has to
  # put the old one away or recall keeps handing her the stale one.
  def tools_in(convo)
    Memory::Tools.new(Memory::Scope.build(personas: [ @velvet ], conversation: convo, request: { "tools" => true, "own" => true }))
  end

  def run_tool(tools, name, arguments)
    outcome = tools.execute({ "id" => "t1", "name" => name, "arguments" => arguments })
    [ JSON.parse(outcome.content), outcome.error ]
  end

  test "remember with replaces supersedes notes of her own, and recall stops handing her the stale ones" do
    convo = conversation(realm: "personal")
    tools = tools_in(convo)
    mine = Memory.remember!(about: @velvet.memory_entity, body: "the worklog hookup will be wired once he approves", realm: "personal", author: @velvet.memory_entity)
    twin = Memory.remember!(about: @velvet.memory_entity, body: "worklog hookup is pending his approval", realm: "personal", author: @velvet.memory_entity)

    said, error = run_tool(tools, "remember", { "body" => "the worklog hookup is wired and live", "replaces" => [ mine.id, twin.id ] })
    refute error, said.inspect
    assert_equal [ mine.id, twin.id ], said["replaced"]
    fresh = Observation.find(said["remembered"])
    assert_equal [ "superseded", "superseded" ], [ mine.reload.status, twin.reload.status ]
    assert_equal [ fresh.id, fresh.id ], [ mine.superseded_by_id, twin.superseded_by_id ]
    assert_equal mine.id, fresh.supersedes_id
    assert_equal [ @velvet.memory_entity.id, convo.id ], [ fresh.author_entity_id, fresh.conversation_id ]

    found, = run_tool(tools, "recall", { "query" => "worklog hookup" })
    assert_equal [ fresh.id ], found["observations"].map { |o| o["id"] }
  end

  test "only her own current notes, and only from the room they were kept in" do
    convo = conversation(realm: "personal")
    tools = tools_in(convo)
    theirs = Memory.remember!(about: @jenner, body: "kat saw a replay.", realm: "personal")
    said, error = run_tool(tools, "remember", { "body" => "x y z", "replaces" => [ theirs.id ] })
    assert error
    assert_match(/not yours to change/, said["error"])
    assert theirs.reload.current?

    # @noted is intimate: out of sight from a personal room.
    said, error = run_tool(tools, "forget", { "id" => @noted.id, "reason" => "stale" })
    assert error
    assert_match(/no current note .* here/, said["error"])

    # From the intimate room, a personal note is seen but stands (rule 4);
    # the new one is still kept, and she is told.
    low = Memory.remember!(about: @velvet.memory_entity, body: "the shed is first", realm: "personal", author: @velvet.memory_entity)
    high = tools_in(conversation(realm: "intimate"))
    said, error = run_tool(high, "remember", { "body" => "the shed is written", "replaces" => [ low.id ] })
    refute error, said.inspect
    assert_equal [ low.id ], said["still_standing"]
    assert_match(/kept in a different room/, said["note"])
    assert_equal "intimate", said["realm"]
    assert low.reload.current?
    said, error = run_tool(high, "forget", { "id" => low.id, "reason" => "stale" })
    assert error
    assert_match(/can only be put away from there/, said["error"])
  end

  test "forget puts one of her notes away with a reason, and a note beside its twin says so" do
    convo = conversation(realm: "personal")
    tools = tools_in(convo)
    body = "MUD project: lives on my real machine in my git repo. one file per room under rooms. the hookup will be wired once he approves"
    stale = Memory.remember!(about: @velvet.memory_entity, body: body, realm: "personal", author: @velvet.memory_entity)
    Memory.remember!(about: @velvet.memory_entity, body: "misha knocked the garlic off the counter again", realm: "personal", author: @velvet.memory_entity)

    said, = run_tool(tools, "remember", { "body" => body.sub("will be wired once he approves", "is wired and live") })
    assert_equal [ stale.id ], said["yours_that_say_nearly_this"].map { |o| o["id"] }, "the stale copy, not the cat"
    assert_match(/forget it by id/, said["hint"])

    gone, error = run_tool(tools, "forget", { "id" => stale.id, "reason" => "the hookup is live now" })
    refute error, gone.inspect
    assert_equal [ "retired", "the hookup is live now", "persona:velvet" ], [ stale.reload.status, stale.retire_reason, stale.retired_by ]
    _, error = run_tool(tools, "forget", { "id" => stale.id, "reason" => "again" })
    assert error, "already put away"

    said, = run_tool(tools, "remember", { "body" => "a wholly different thing about kerbal mods and orbital mechanics" })
    refute said.key?("yours_that_say_nearly_this")
  end

  test "the model is offered forget beside recall and remember" do
    @velvet.update!(memory: { "tools" => true })
    convo = conversation(realm: "personal")
    @fake.reply("ok")
    turn(convo, content: "hi").call
    assert_equal %w[recall remember forget], @fake.calls.last.tools.map { |t| t["name"] }
    assert_includes @fake.calls.last.tools.find { |t| t["name"] == "remember" }["input_schema"]["properties"].keys, "replaces"
  end
end
