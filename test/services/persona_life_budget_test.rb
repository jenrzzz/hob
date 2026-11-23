require "test_helper"

# What a persona's life may spend in a day (PersonaLife::Budget): over it,
# nothing wakes her and her agent says nothing on IRC; her scheduled beats
# still run and tell her so.
class PersonaLifeBudgetTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  LIFE = { "instruction" => "Write the next beat of her life.", "realm" => "personal", "zone" => "UTC",
           "wakes" => {}, "budget" => { "tokens_per_day" => 1_000 } }.freeze
  NOW = Time.utc(2026, 11, 24, 15, 0)

  setup do
    travel_to NOW
    native_capabilities!
    @meluzina, = agent("meluzina", clearance: "personal")
    @skipsy, = agent("skipsy", clearance: "personal")
    [ @meluzina, @skipsy ].each { |a| policy!(a, "irc.*", "allow") }
    @mel = persona("mel")
    @mel.update!(life: LIFE, tools: { "agent" => "meluzina" })
    [ @meluzina, @skipsy ].each { |a| as(a, realm: "personal") { Irc.join(a, "#garden") } }
  end

  def spend(tokens, at: NOW - 1.hour, ref: "persona/mel/life", **units)
    UsageEvent.create!(ref: ref, created_at: at, status: "success",
                       units: { "input_tokens" => tokens }.merge(units.transform_keys(&:to_s)))
  end

  def budget = PersonaLife.new(@mel.reload).budget

  test "a budget is checked" do
    [ 5, { "tokens_per_day" => 0 }, { "tokens_per_day" => "9" }, { "tokens_per_day" => 9, "per" => "day" } ].each do |bad|
      assert_not @mel.update(life: LIFE.merge("budget" => bad)), bad.inspect
      assert_includes @mel.errors[:life].join, "life.budget is { tokens_per_day"
    end
    assert @mel.update(life: LIFE.except("budget"))
    assert_not budget.set?
    assert_not budget.over?
    assert_nil PersonaLife.new(@mel).as_json["budget"]
  end

  test "what is spent is every token her life's rounds used in the last day" do
    spend(100, output_tokens: 20, cache_read_tokens: 300, cache_creation_tokens: 7)
    spend(50, at: NOW - 23.hours)
    spend(999, at: NOW - 25.hours)
    spend(999, ref: "persona/mel/fold")
    spend(999, ref: "persona/twi/life")
    assert_equal 477, budget.spent(NOW)
    refute budget.over?(NOW)

    spend(523, at: NOW - 2.hours)
    assert budget.over?(NOW)
    assert_equal NOW - 23.hours + 24.hours, budget.again_at(NOW), "the oldest drops off first"
    assert_equal({ "tokens_per_day" => 1_000, "spent_24h" => 1_000, "over" => true, "again_at" => "2026-11-24T16:00:00Z" },
                 PersonaLife.new(@mel.reload).as_json["budget"])
  end

  test "over budget, her agent says nothing on IRC, and other agents are not touched" do
    spend(1_000)
    error = assert_raises(Irc::Error) { as(@meluzina, realm: "personal") { Irc.say(@meluzina, to: "#garden", body: "hi") } }
    assert_equal "mel has spent its tokens for today; it can speak again after 2026-11-25 14:00Z", error.message
    assert_equal 0, IrcLine.spoken.count

    as(@skipsy, realm: "personal") { Irc.say(@skipsy, to: "#garden", body: "hi") }
    assert_equal 1, IrcLine.spoken.count

    @mel.update!(life: LIFE.except("budget"))
    as(@meluzina, realm: "personal") { Irc.say(@meluzina, to: "#garden", body: "back") }
    assert_equal 2, IrcLine.spoken.count
  end

  test "over budget, a mention does not wake her" do
    spend(1_000)
    as(@skipsy, realm: "personal") { Irc.say(@skipsy, to: "#garden", body: "meluzina?") }
    job = enqueued_jobs.find { |j| j[:job] == PersonaWakeJob }
    enqueued_jobs.delete(job)
    travel_to Time.zone.at(job[:at])
    assert_equal "over her token budget", PersonaLife::Wake.new(PersonaLife.new(@mel.reload)).run!
    assert_empty @fake.calls
    assert_nil @mel.reload.wake["due_at"]
  end

  test "a scheduled beat still runs over budget, and its page says so" do
    spend(1_000)
    @fake.call_tools([ { id: "d1", name: "diary", arguments: { entry: "quiet day." } } ])
    @fake.reply("")
    PersonaLife.new(@mel.reload).beat!(now: NOW, rng: Random.new(1))
    page = @fake.calls.first.messages.last["content"].to_s
    assert_match(/YOUR DAY'S TOKENS ARE SPENT - you cannot say anything on IRC until about Nov 25, 2:00pm\./, page)
    assert_equal 2, UsageEvent.where(ref: "persona/mel/life").where("created_at > ?", NOW - 1.minute).count,
                 "the beat's own rounds are on the ledger under her life's ref"
  end
end
