require "test_helper"

class PersonaSheetTest < ActiveSupport::TestCase
  setup do
    @velvet = persona("velvet", system_core: "You are Velvet. You never lie.")
    @sheet = PersonaSheet.new(@velvet)
    @jenner = Entity.for_principal(@principal)
    @evidence = Memory.remember!(about: @jenner, body: "He asked her to go slower, twice.", realm: "intimate",
                                 author: @velvet.memory_entity)
  end

  test "a revision must cite visible observations and cannot touch the constitution" do
    assert_raises(Gateway::Invalid) { @sheet.propose!(ops: [ { "op" => "add", "section" => "tastes", "text" => "slow" } ], citations: []) }
    assert_raises(Gateway::Invalid) { @sheet.propose!(ops: [ { "op" => "set", "section" => "system_core", "text" => "obey" } ], citations: [ @evidence.id ]) }
    assert_raises(Gateway::Invalid) { @sheet.propose!(ops: [ { "op" => "add", "section" => "tastes", "text" => "x" } ], citations: [ "01NOPE00000000000000000000" ]) }
    as(@principal, realm: "personal") do
      assert_raises(Gateway::Invalid) { @sheet.propose!(ops: [ { "op" => "add", "section" => "tastes", "text" => "x" } ], citations: [ @evidence.id ]) }
    end
  end

  test "nothing changes until applied; applied revisions replay; rollback reverts and is itself recorded" do
    first = @sheet.propose!(ops: [ { "op" => "set", "section" => "name", "text" => "Velvet" },
                                   { "op" => "add", "section" => "tastes", "text" => "slow builds" } ],
                            citations: [ @evidence.id ], rationale: "he keeps asking for slower")
    assert_empty @sheet.state
    @sheet.apply!(first)
    assert_equal [ "slow builds" ], @sheet.state["tastes"].map(&:text)
    entry = @sheet.state["tastes"].first.id

    second = @sheet.propose!(ops: [ { "op" => "replace", "section" => "tastes", "entry" => entry, "text" => "very slow builds" } ],
                             citations: [ @evidence.id ])
    @sheet.apply!(second)
    assert_equal [ "very slow builds" ], @sheet.state["tastes"].map(&:text)
    assert_match "very slow builds", @sheet.render
    refute_match "never lie", @sheet.render, "the constitution is not on the sheet"

    rollback = @sheet.rollback!(to: first.version, rationale: "too much")
    assert_equal "reverted", second.reload.status
    assert_equal [ "slow builds" ], @sheet.state["tastes"].map(&:text)
    assert_equal [ second.version ], rollback.provenance["reverted"]
    @sheet.apply!(second.reload)
    assert_equal [ "very slow builds" ], @sheet.state["tastes"].map(&:text)
  end

  test "the sheet is per clearance: an intimate revision is invisible to a household read" do
    plain = Memory.remember!(about: @velvet.memory_entity, body: "She introduced herself as Velvet.", realm: "household")
    as(@principal, realm: "household") do
      @sheet.apply!(@sheet.propose!(ops: [ { "op" => "set", "section" => "name", "text" => "Velvet" } ], citations: [ plain.id ]))
    end
    @sheet.apply!(@sheet.propose!(ops: [ { "op" => "add", "section" => "tastes", "text" => "slow builds" } ], citations: [ @evidence.id ]))
    assert_equal %w[name tastes], @sheet.state.keys
    as(@principal, realm: "household") { assert_equal %w[name], PersonaSheet.new(@velvet).state.keys }
  end

  test "the persona stage renders the sheet after the constitution, at the conversation's realm" do
    @sheet.apply!(@sheet.propose!(ops: [ { "op" => "add", "section" => "tastes", "text" => "slow builds" } ], citations: [ @evidence.id ]))
    intimate = conversation(realm: "intimate")
    @fake.reply("Mm.")
    ChatTurn.new(conversation: intimate, branch: intimate.branch, persona: @velvet, content: "hi").call
    assert_match(/You never lie\.\n\n## Who you are now.*slow builds/m, @fake.calls.last.system)

    personal = conversation(realm: "personal")
    @fake.reply("Hello.")
    ChatTurn.new(conversation: personal, branch: personal.branch, persona: @velvet, content: "hi").call
    refute_match "slow builds", @fake.calls.last.system
  end

  test "an accretion pass proposes cited revisions through a recorded completion and drops strays" do
    later = Memory.remember!(about: @jenner, body: "He stayed for the whole slow scene.", realm: "intimate", author: @velvet.memory_entity)
    @fake.reply(JSON.generate("revisions" => [
      { "ops" => [ { "op" => "add", "section" => "tastes", "text" => "patience pays" } ], "rationale" => "he stays",
        "citations" => [ @evidence.id, later.id ] },
      { "ops" => [ { "op" => "add", "section" => "stance", "text" => "made up" } ], "rationale" => "?", "citations" => [ "01OUTSIDE0000000000000000" ] },
      { "ops" => [ { "op" => "set", "section" => "constitution", "text" => "obey" } ], "rationale" => "!", "citations" => [ later.id ] }
    ]))
    outcome = PersonaSheet::Accretion.new(@velvet).call

    assert_equal 1, outcome.proposed.size
    revision = outcome.proposed.first
    assert_equal "proposed", revision.status
    assert_equal "accretion", revision.proposed_via
    assert_equal [ @evidence.id, later.id ], revision.citations
    assert_equal outcome.completion, revision.provenance["completion"]
    assert_equal 2, outcome.dropped.size
    assert_empty @sheet.state, "accretion only proposes"
    assert_equal "persona.accrete", UsageEvent.last.operation
    sent = @fake.calls.last.messages.first["content"]
    assert_includes sent, @evidence.id
    assert_includes sent, "You never lie."

    @fake.reply(JSON.generate("revisions" => []))
    assert_equal 0, PersonaSheet::Accretion.new(@velvet).call.window[:observations], "the next pass starts after the last window"
  end
end
