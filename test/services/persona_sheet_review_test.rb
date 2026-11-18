require "test_helper"

class PersonaSheetReviewTest < ActiveSupport::TestCase
  setup do
    @velvet = persona("velvet", system_core: "You are Velvet. You never lie.")
    @sheet = PersonaSheet.new(@velvet)
    @jenner = Entity.for_principal(@principal)
    @hers = Memory.remember!(about: @jenner, body: "Opened with Random again.", realm: "intimate", author: @velvet.memory_entity)
    @unused = Memory.remember!(about: @jenner, body: "He holds real photos longest.", realm: "intimate", kind: "evidence")
    applied = @sheet.propose!(ops: [ { "op" => "add", "section" => "habits", "text" => "I open with Random." } ], citations: [ @hers.id ])
    @sheet.apply!(applied)
    @entry = @sheet.state["habits"].first.id
    ModelRole.create!(role: "review", chain: [ { "provider" => "anthropic", "model" => "claude-fable-5-2" } ])
  end

  test "a review needs its own model role" do
    ModelRole.where(role: "review").delete_all
    assert_raises(Gateway::Invalid) { PersonaSheet::Review.new(@velvet) }
  end

  test "a review proposes cited revisions and records insights about him and ruts about her" do
    @fake.reply(JSON.generate(
      "revisions" => [
        { "ops" => [ { "op" => "replace", "section" => "habits", "entry" => @entry, "text" => "I open where he held longest." } ],
          "rationale" => "the opening never varies", "citations" => [ @hers.id, @unused.id ] },
        { "ops" => [ { "op" => "add", "section" => "stance", "text" => "made up" } ], "rationale" => "?", "citations" => [ "01OUTSIDE0000000000000000" ] }
      ],
      "notes" => [
        { "kind" => "rut", "body" => "You open with Random every time.", "citations" => [ @hers.id ] },
        { "kind" => "insight", "body" => "His hands prefer photographs to his words.", "citations" => [ @unused.id ] },
        { "kind" => "insight", "body" => "Uncited.", "citations" => [] }
      ]
    ))
    outcome = PersonaSheet::Review.new(@velvet).call

    assert_equal 1, outcome.proposed.size
    assert_equal [ "proposed", "review" ], outcome.proposed.first.values_at(:status, :proposed_via)
    assert_equal [ "I open with Random." ], @sheet.state["habits"].map(&:text), "a review only proposes"
    assert_equal 2, outcome.dropped.size

    rut = outcome.ruts.sole
    assert_equal [ @velvet.memory_entity, nil, "intimate" ], [ rut.entity, rut.author_entity, rut.realm ]
    assert_equal [ "observation:#{@hers.id}" ], rut.evidence
    assert_equal @jenner, outcome.insights.sole.entity

    sent = @fake.calls.last.messages.first["content"]
    assert_includes sent, @unused.id
    assert_includes sent, "[#{@entry}] I open with Random."
    assert_equal "persona.review", UsageEvent.last.operation
    assert_in_delta Time.current, PersonaSheet::Review.last_at(@velvet), 5

    # The rut is about her, so her next accretion pass reads it.
    @fake.reply(JSON.generate("revisions" => []))
    PersonaSheet::Accretion.new(@velvet).call
    assert_includes @fake.calls.last.messages.first["content"], "You open with Random every time."
  end

  test "the clock reviews a persona that asked, at her realm, and not again until she is due" do
    @velvet.update!(memory: { "review" => { "every_days" => 7, "realm" => "intimate" } })
    other = persona("plain")
    Memory.remember!(about: @jenner, body: "x", realm: "intimate", author: other.memory_entity)

    @fake.reply(JSON.generate("revisions" => [], "notes" => []))
    assert_difference -> { @fake.calls.size }, 1 do
      PersonaReviewJob.perform_now
      PersonaReviewJob.perform_now
    end
    @fake.reply(JSON.generate("revisions" => [], "notes" => []))
    assert_difference -> { @fake.calls.size }, 1 do
      PersonaReviewJob.perform_now(now: 8.days.from_now)
    end
  end
end
