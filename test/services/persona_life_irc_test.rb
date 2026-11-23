require "test_helper"

# A persona on hob's IRC (IRC.md): she is there as her agent, a beat of her
# life says who is waiting on her without marking anything read, and in a
# beat or a turn irc.* are her own tools.
class PersonaLifeIrcTest < ActiveSupport::TestCase
  LIFE = { "instruction" => "Write the next beat of her life.", "realm" => "personal", "zone" => "America/Chicago" }.freeze

  setup do
    native_capabilities!
    @agent, = agent("meluzina", clearance: "personal")
    @skipsy, = agent("skipsy")
    @mel = persona("mel")
    @mel.update!(life: LIFE, tools: { "agent" => "meluzina" })
  end

  def prompt
    Clearance.with("personal") { PersonaLife::Beat.new(PersonaLife.new(@mel.reload), now: Time.current, rng: Random.new(1)).prompt }
  end

  def on_irc(who, realm: "household")
    as(who, realm: realm) { yield }
  end

  test "a beat says nothing of IRC to a persona whose agent is not on it" do
    refute_match(/IRC/, prompt)
  end

  test "a beat says where she is on IRC and what is waiting, and looking for her marks nothing" do
    policy!(@agent, "irc.*", "allow")
    assert_match(/IRC - hob has a small IRC of its own.*You are meluzina there/, prompt)
    assert_match(/You are in no channel yet\./, prompt)

    on_irc(@skipsy) do
      Irc.join(@skipsy, "#garden")
      Irc.topic(@skipsy, "#garden", "what is growing")
      Irc.join(@skipsy, "#shed")
    end
    assert_match(/Channels you are not in: #garden \(skipsy\); #shed \(skipsy\)/, prompt)
    refute_match(/what is growing/, prompt, "a topic is another agent's words: read as data, not put on her page")

    on_irc(@agent) { Irc.join(@agent, "#garden") }
    @agent.update!(accepts_lower_messages: true)
    on_irc(@skipsy) do
      Irc.say(@skipsy, to: "#garden", body: "meluzina: did the quince take?\nit rained all night here")
      Irc.say(@skipsy, to: "meluzina", body: "also, hello")
    end

    2.times do
      text = prompt
      assert_match(/^- #garden \(with skipsy\): 2 new, 1 naming you$/, text)
      assert_match(/^- your DM with skipsy: 1 new$/, text)
      assert_match(/Channels you are not in: #shed \(skipsy\)/, text)
      refute_match(/did the quince take/, text, "what was said is read with irc_read, as data, not put on the page")
    end

    on_irc(@agent) { Irc.read(@agent, target: "#garden") }
    assert_match(/^- #garden \(with skipsy\): nothing new$/, prompt)
  end

  test "in a beat she reads and answers as her agent, at her life's realm" do
    policy!(@agent, "irc.*", "allow")
    on_irc(@skipsy) { Irc.join(@skipsy, "#garden") }
    on_irc(@agent) { Irc.join(@agent, "#garden") }
    on_irc(@skipsy) { Irc.say(@skipsy, to: "#garden", body: "anyone about?") }

    @fake.call_tools([ { id: "r1", name: "irc_read", arguments: { target: "#garden" } } ])
    @fake.call_tools([ { id: "s1", name: "irc_say", arguments: { to: "#garden", body: "I am. the kettle's on" } },
                       { id: "d1", name: "diary", arguments: { entry: "talked to skipsy over the fence, so to speak." } } ])
    @fake.reply("")
    PersonaLife.new(@mel.reload).beat!(now: Time.utc(2026, 11, 24, 15, 0), rng: Random.new(1))

    assert_includes @fake.calls.first.tools.map { |t| t["name"] }, "irc_say"
    line = IrcLine.spoken.in_order.last
    assert_equal [ "meluzina", "I am. the kettle's on", "household" ], [ line.nick, line.body, line.realm ]
    request = @agent.sentinel_requests.find(line.sentinel_request_id)
    assert_equal [ "irc.say", "life", "personal" ], [ request.capability.name, request.surface, request.realm ]
    assert_equal 1, on_irc(@skipsy) { Irc.channels(@skipsy) }["channels"].sole["new"]
  end
end
