require "test_helper"

# irc.* (IRC.md): hob's own IRC. Agents, and personas through their agent,
# join channels, talk, and DM each other; a line waits until whoever it is
# for next looks. Realm is the fence; each act is a request row.
class IrcCapabilitiesTest < ActiveSupport::TestCase
  NAMES = %w[irc.channels irc.join irc.part irc.say irc.read irc.topic].freeze

  setup do
    native_capabilities!
    @skipsy, = agent("skipsy")
    @marley, = agent("marley")
    @meluzina, = agent("meluzina", clearance: "personal")
    policy!(nil, "irc.*", "allow")
  end

  def submit(capability, arguments = {}, agent: @skipsy, realm: nil)
    realm ||= agent.max_clearance
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments) }
  end

  def completed(capability, arguments = {}, **options)
    request = submit(capability, arguments, **options)
    assert_equal "completed", request.status, request.error.to_s
    request.result
  end

  def failed(capability, arguments = {}, **options)
    request = submit(capability, arguments, **options)
    assert_equal "failed", request.status
    request.error
  end

  def words(log)
    log.map { |line| line.sub(/\A\[[^\]]+\] /, "") }
  end

  test "sync! registers the six capabilities at household, with closed schemas" do
    caps = Capability.where(name: NAMES).index_by(&:name)
    assert_equal NAMES.sort, caps.keys.sort
    assert_equal %w[irc.channels irc.read], caps.values.select { |c| c.kind == "read" }.map(&:name).sort
    caps.each_value do |cap|
      assert cap.native?
      assert_equal "household", cap.realm
      assert_equal false, cap.input_schema["additionalProperties"], cap.name
    end
  end

  test "joining opens a channel; what is said waits for the others, and reading marks it read" do
    joined = completed("irc.join", { "channel" => "#Garden" })
    assert_equal "#garden", joined["channel"]
    assert joined["created"]
    assert_equal %w[skipsy], joined["members"]
    assert_equal Irc::NOTICE, joined["notice"]

    said = submit("irc.say", { "to" => "#garden", "body" => "anyone about?\nthe quince is in" })
    assert_equal "completed", said.status, said.error.to_s
    assert_equal [ "<skipsy> anyone about?", "<skipsy> the quince is in" ], words(said.result["said"])
    assert_equal [ said.id ], IrcLine.spoken.pluck(:sentinel_request_id).uniq, "a line names the request that said it"

    arrived = completed("irc.join", { "channel" => "#garden" }, agent: @marley)
    assert_nil arrived["created"]
    assert_equal %w[marley skipsy], arrived["members"]
    assert_equal [ "-- skipsy joined #garden", "<skipsy> anyone about?", "<skipsy> the quince is in" ], words(arrived["backlog"])
    assert_match(/\A\[\d{4}-\d\d-\d\d \d\d:\d\dZ\] /, arrived["backlog"].first)

    completed("irc.say", { "to" => "#garden", "body" => "skipsy: how many?" }, agent: @marley)
    completed("irc.say", { "to" => "#garden", "body" => "counts on fingers", "action" => true }, agent: @marley)

    listing = completed("irc.channels")
    assert_equal "skipsy", listing["nick"]
    garden = listing["channels"].sole
    assert_equal({ "name" => "#garden", "members" => %w[marley skipsy], "joined" => true, "new" => 2, "naming_you" => 1 },
                 garden.except("last_line_at"))
    assert_equal 2, completed("irc.channels")["channels"].sole["new"], "looking at the list marks nothing"

    read = completed("irc.read", { "target" => "#garden" })
    assert_equal [ "-- marley joined #garden", "<marley> skipsy: how many?", "* marley counts on fingers" ], words(read["log"])
    assert_equal 2, read["new"]
    assert_equal 0, read["more"]

    again = completed("irc.read", { "target" => "#garden" })
    assert_equal 0, again["new"]
    assert_match(/nothing new/, again["note"])
    assert_equal "* marley counts on fingers", words(again["log"]).last, "the window still shows its last lines"
    assert_equal 0, completed("irc.channels")["channels"].sole["new"]

    older = completed("irc.read", { "target" => "#garden", "before" => read["first_id"], "limit" => 2 })
    assert_equal [ "<skipsy> anyone about?", "<skipsy> the quince is in" ], words(older["log"])
    assert_nil older["note"]
  end

  test "someone who speaks before reading keeps their place, and reads their own line in among the rest" do
    completed("irc.join", { "channel" => "#garden" })
    completed("irc.join", { "channel" => "#garden" }, agent: @marley)
    completed("irc.say", { "to" => "#garden", "body" => "the gate was open" }, agent: @marley)

    assert_equal 1, completed("irc.say", { "to" => "#garden", "body" => "morning" })["new"]
    assert_equal [ "-- marley joined #garden", "<marley> the gate was open", "<skipsy> morning" ],
                 words(completed("irc.read", { "target" => "#garden" })["log"])
  end

  test "reading past the limit leaves the rest waiting" do
    completed("irc.join", { "channel" => "#garden" })
    completed("irc.join", { "channel" => "#garden" }, agent: @marley)
    2.times { |i| completed("irc.say", { "to" => "#garden", "body" => "one #{i}\ntwo #{i}\nthree #{i}" }, agent: @marley) }

    first = completed("irc.read", { "target" => "#garden", "limit" => 3 })
    assert_equal [ "-- marley joined #garden", "<marley> one 0", "<marley> two 0" ], words(first["log"])
    assert_equal 2, first["new"], "a join is shown but is not somebody speaking"
    assert_equal 4, first["more"]
    assert_equal 4, completed("irc.read", { "target" => "#garden" })["new"]
  end

  test "a channel is for those in it: no reading or speaking from outside, and parting leaves the lines" do
    completed("irc.join", { "channel" => "#garden" })
    completed("irc.say", { "to" => "#garden", "body" => "hello" })

    assert_match(/you are not in #garden; join it first/, failed("irc.say", { "to" => "#garden", "body" => "hi" }, agent: @marley))
    assert_match(/you are not in #garden/, failed("irc.read", { "target" => "#garden" }, agent: @marley))
    assert_match(/there is no #shed; irc.join opens it/, failed("irc.say", { "to" => "#shed", "body" => "hi" }))
    assert_match(/a channel is #/, failed("irc.join", { "channel" => "garden" }))
    assert_equal false, completed("irc.channels", {}, agent: @marley)["channels"].sole["joined"]

    assert completed("irc.join", { "channel" => "#garden" })["already"], "joining twice is not an event"
    assert_equal 1, IrcLine.where(kind: "join").count

    assert completed("irc.part", { "channel" => "#garden" })["parted"]
    assert_match(/you are not in #garden/, failed("irc.part", { "channel" => "#garden" }))
    assert_equal [ "-- skipsy joined #garden", "<skipsy> hello", "-- skipsy left #garden" ], words(IrcLine.in_order.map(&:to_log))
  end

  test "what is said is plain lines within limits" do
    completed("irc.join", { "channel" => "#garden" })
    assert_match(/at most 400 characters/, failed("irc.say", { "to" => "#garden", "body" => "x" * 401 }))
    assert_match(/at most 5 lines/, failed("irc.say", { "to" => "#garden", "body" => (1..6).to_a.join("\n") }))
    assert_match(/nothing to say/, failed("irc.say", { "to" => "#garden", "body" => " \n " }))

    said = completed("irc.say", { "to" => "#garden", "body" => "bold\u0002 and \u000304red\u0003  spaced" })
    assert_equal [ "<skipsy> bold and 04red spaced" ], words(said["said"]), "control characters do not get through"
    assert_equal 0, IrcLine.where("body ~ '[[:cntrl:]]'").count
  end

  test "a topic is set by someone in the channel, and the channel sees who" do
    completed("irc.join", { "channel" => "#garden" })
    assert_match(/you are not in #garden/, failed("irc.topic", { "channel" => "#garden", "topic" => "mine now" }, agent: @marley))

    assert_equal "what is growing", completed("irc.topic", { "channel" => "#garden", "topic" => " what is\ngrowing " })["topic"]
    channel = IrcChannel.find_by!(name: "#garden")
    assert_equal [ "what is growing", "skipsy" ], [ channel.topic, channel.topic_by ]
    assert_equal "-- skipsy set the topic: what is growing", words([ IrcLine.last.to_log ]).first
    assert_equal "what is growing", completed("irc.join", { "channel" => "#garden" }, agent: @marley)["topic"]

    assert_nil completed("irc.topic", { "channel" => "#garden", "topic" => "" })["topic"]
    assert_nil channel.reload.topic
  end

  test "a DM is opened by its first line and read only by its two ends" do
    said = completed("irc.say", { "to" => "marley", "body" => "you up?" })
    assert_equal "marley", said["to"]
    dm = IrcChannel.dms.sole
    assert_equal [ "marley,skipsy", "household" ], [ dm.name, dm.realm ]

    assert_equal [ { "with" => "skipsy", "new" => 1 } ],
                 completed("irc.channels", {}, agent: @marley)["dms"].map { |d| d.except("last_line_at") }
    read = completed("irc.read", { "target" => "skipsy" }, agent: @marley)
    assert_equal [ "<skipsy> you up?" ], words(read["log"])
    assert_equal "skipsy", read["target"]
    completed("irc.say", { "to" => "skipsy", "body" => "barely" }, agent: @marley)
    assert_equal 1, IrcChannel.dms.count, "the answer goes into the same DM"
    assert_equal [ "<marley> barely" ], words(completed("irc.read", { "target" => "marley" })["log"])

    butler, = agent("butler")
    assert_empty completed("irc.channels", {}, agent: butler)["dms"]
    assert_match(/nothing has been said between you/, completed("irc.read", { "target" => "skipsy" }, agent: butler)["note"])
    assert_empty completed("irc.read", { "target" => "skipsy" }, agent: butler)["log"]
  end

  test "a DM goes to an agent, not to a person, a stranger, or oneself" do
    Principal.create!(name: "mise-worker", kind: "worker", max_clearance: "household")
    { "nobody" => /nobody on IRC goes by "nobody"/, "tester" => /tester is a human, not an agent/,
      "mise-worker" => /mise-worker is a worker, not an agent/, "skipsy" => /that is you/ }.each do |to, error|
      assert_match error, failed("irc.say", { "to" => to, "body" => "hello" }), to
    end
    assert_equal 0, IrcChannel.count
  end

  test "a DM is kept at the lower clearance; an agent cleared higher hears from below only once its inbox is open" do
    assert_match(/meluzina is cleared above household and does not take DMs from below it/,
                 failed("irc.say", { "to" => "meluzina", "body" => "hello up there" }))

    sent = completed("irc.say", { "to" => "skipsy", "body" => "hello down there" }, agent: @meluzina)
    assert_equal "household", IrcChannel.dms.sole.realm
    assert_equal 0, sent["new"]
    assert_match(/does not take DMs from below/, failed("irc.say", { "to" => "meluzina", "body" => "hi" }),
                 "being written to does not open her inbox")
    assert_equal [ "<meluzina> hello down there" ], words(completed("irc.read", { "target" => "meluzina" })["log"])

    @meluzina.update!(accepts_lower_messages: true)
    completed("irc.say", { "to" => "meluzina", "body" => "hi" })
    assert_equal [ "<skipsy> hi" ], words(completed("irc.read", { "target" => "skipsy" }, agent: @meluzina)["log"])
  end

  test "two agents cleared personal keep their DM at personal, out of a household turn's reach" do
    robyn, = agent("robyn", clearance: "personal")
    completed("irc.say", { "to" => "robyn", "body" => "just us" }, agent: @meluzina)
    assert_equal "personal", IrcChannel.dms.sole.realm

    assert_match(/a DM with robyn is kept at personal, above where you are asking from \(household\)/,
                 failed("irc.say", { "to" => "robyn", "body" => "from the kitchen" }, agent: @meluzina, realm: "household"))
    assert_empty completed("irc.channels", {}, agent: @meluzina, realm: "household")["dms"]
    assert_equal 1, completed("irc.channels", {}, agent: robyn)["dms"].sole["new"]
  end

  test "a channel a person made higher does not exist below it" do
    Irc.channel_by_person!("#upstairs", realm: "personal", topic: "not for the kitchen", by: @principal)

    assert_equal "not for the kitchen", completed("irc.join", { "channel" => "#upstairs" }, agent: @meluzina)["topic"]
    completed("irc.say", { "to" => "#upstairs", "body" => "quiet up here" }, agent: @meluzina)
    assert_equal %w[personal], IrcLine.distinct.pluck(:realm)

    assert_empty completed("irc.channels")["channels"], "skipsy asks at household"
    assert_match(/#upstairs cannot be opened/, failed("irc.join", { "channel" => "#upstairs" }))
    assert_empty completed("irc.channels", {}, agent: @meluzina, realm: "household")["channels"]
    assert_match(/there is no #upstairs/, failed("irc.read", { "target" => "#upstairs" }, agent: @meluzina, realm: "household"))

    assert_raises(Irc::Error) { Irc.channel_by_person!("#upstairs", realm: "household") }
  end

  test "policy still decides: an agent with no rule for irc is not on it" do
    SentinelPolicy.delete_all
    policy!(@skipsy, "irc.*", "allow")
    assert_equal "denied", submit("irc.join", { "channel" => "#garden" }, agent: @marley).status
    assert_equal "completed", submit("irc.join", { "channel" => "#garden" }).status
  end

  test "a person's assistant reads any channel and marks nothing, and cannot speak" do
    completed("irc.join", { "channel" => "#garden" })
    completed("irc.say", { "to" => "#garden", "body" => "hello" })
    completed("irc.say", { "to" => "marley", "body" => "psst" })

    as(@principal, realm: "intimate", surface: "test") do
      assert_equal %w[irc_channels irc_read], Mcp.tools.keys.grep(/\Airc_/).sort
      listing = Mcp.call("irc_channels", {})
      assert_equal [ { "name" => "#garden", "members" => %w[skipsy], "joined" => false } ],
                   listing["channels"].map { |c| c.except("last_line_at") }
      assert_equal [ "-- skipsy joined #garden", "<skipsy> hello" ], words(Mcp.call("irc_read", { "target" => "#garden" })["log"])
      dm = Mcp.call("irc_read", { "target" => "marley,skipsy" })
      assert_equal [ "marley,skipsy", [ "<skipsy> psst" ] ], [ dm["target"], words(dm["log"]) ], "the household can read a DM"
    end
    assert_equal 1, as(@marley, realm: "household") { Irc.channels(@marley) }["dms"].sole["new"], "and marley's is still unread"
    assert_raises(Irc::Error) { Irc.say(@principal, to: "#garden", body: "it's me") }
  end
end
