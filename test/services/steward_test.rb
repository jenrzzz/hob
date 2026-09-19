require "test_helper"

# Petitions (SENTINEL.md, "Petitions and the forge"): an agent asks for a
# capability it does not have, and the steward grants, builds, refers, or
# denies under the charter.
class StewardTest < ActiveSupport::TestCase
  setup do
    native_capabilities!
    @muse, _token = agent("muse")
    @pings = []
    Notify.transport = ->(url, title, body, _headers) { @pings << [ url, title, body ] }
    ENV["HOB_NOTIFY_URL"] = "https://ntfy.test/hob"
  end

  teardown do
    Notify.transport = nil
    ENV.delete("HOB_NOTIFY_URL")
  end

  def petition(want, capability: nil, arguments: {}, reason: nil, agent: @muse, realm: "household", on_mission: nil)
    as(agent, realm: realm) do
      Sentinel.petition!(agent: agent, want: want, capability: capability, arguments: arguments, reason: reason, on_mission: on_mission)
    end
  end

  def steward_says(action, capability: "", effect: "review", rationale: "because", spec: nil, constraints: "{}", limits: "{}", guidance: "")
    spec ||= { "description" => "", "kind" => "read", "realm" => "household", "input_schema_json" => "{}", "behaviour" => "",
               "result_json" => "{}", "acceptance" => "", "notes" => "" }
    @fake.reply({ "action" => action, "rationale" => rationale, "capability" => capability, "effect" => effect,
                  "constraints_json" => constraints, "limits_json" => limits, "guidance" => guidance, "spec" => spec }.to_json)
  end

  def calendar_spec
    { "description" => "Read the household calendar for a date range.", "kind" => "read", "realm" => "household",
      "input_schema_json" => { "type" => "object", "properties" => { "from" => { "type" => "string" }, "to" => { "type" => "string" } },
                               "required" => %w[from] }.to_json,
      "behaviour" => "Query the calendar events table between from and to; return them.",
      "result_json" => { "events" => [] }.to_json, "acceptance" => "1. returns events in range\n2. rejects a missing from",
      "notes" => "read only" }
  end

  test "no charter means the agent may not petition; a deny charter says so too" do
    row = petition("read my own usage")
    assert_equal "denied", row.status
    assert_equal "policy", row.decided_by
    assert_match(/no policy permits muse to petition/, row.rationale)
    assert_empty @fake.calls

    charter!(@muse, "deny")
    assert_equal "denied", petition("read my own usage").status
    assert_raises(Sentinel::Invalid) { petition("") }
    assert_raises(Sentinel::Invalid) { petition("x", capability: "Not A Name") }
    assert_raises(Sentinel::Invalid) { as(@principal, realm: "household") { Sentinel.petition!(agent: @principal, want: "x") } }
  end

  test "grant: the steward writes a policy rule for an existing capability, bounded by kind" do
    charter!(@muse, "review", guidance: "Muse works for Tessa. Reads of its own data are fine.")
    steward_says("grant", capability: "hob.usage", effect: "allow", rationale: "its own spend", limits: '{"per_day": 50}')

    row = petition("see how much I have spent today", reason: "budget check")
    assert_equal "granted", row.status
    assert_equal "grant", row.action
    assert_equal "steward", row.decided_by
    assert_equal "hob.usage", row.capability_name
    assert_equal "allow", row.effect
    rule = row.sentinel_policy
    assert_equal @muse, rule.principal
    assert_equal "hob.usage", rule.capability
    assert_equal "allow", rule.effect
    assert_equal({ "per_day" => 50 }, rule.limits)
    assert Conversation.find(row.review["completion"]).pipeline?
    assert_equal "sentinel.steward", UsageEvent.last.operation
    assert_equal @muse, UsageEvent.last.principal
    assert_equal "petition/#{row.id}", UsageEvent.last.ref
    call = @fake.calls.last
    assert_match(/Reads of its own data are fine/, call.system)
    assert_match(/budget check/, call.messages.last["content"])
    assert_match(/hob.usage — read, household/, call.messages.last["content"])
    assert_match(/grant existing capabilities; a build is referred/, call.messages.last["content"])
    assert_empty @pings

    # The agent can now ask.
    request = as(@muse, realm: "household") { Sentinel.submit!(agent: @muse, capability: "hob.usage") }
    assert_equal "completed", request.status

    # An act capability is capped at review whatever the steward says.
    steward_says("grant", capability: "hob.conversation.event", effect: "allow")
    row = petition("note what I did on conversations")
    assert_equal "granted", row.status
    assert_equal "review", row.sentinel_policy.effect
  end

  test "the steward's JSON-schema-flavoured constraints and odd limits are normalized, never a validation error" do
    charter!(@muse, "allow")
    steward_says("grant", capability: "hob.usage", effect: "allow",
                 constraints: { "surface" => { "enum" => [ "muse" ], "default" => "muse", "description" => "own" },
                                "since" => { "pattern" => "\\A2026", "type" => "string" }, "ref" => { "maxLength" => 40 },
                                "role" => [ "cheap-classifier" ], "junk" => { "type" => "string" } }.to_json,
                 limits: { "per_hour" => 10, "per_day" => 50, "cost_per_day" => -1, "builds_per_day" => 9, "tokens" => 5 }.to_json)
    row = petition("see my spend")
    assert_equal "granted", row.status
    rule = row.sentinel_policy
    assert_equal({ "surface" => { "in" => [ "muse" ] }, "since" => { "pattern" => "\\A2026" }, "ref" => { "max" => 40 },
                   "role" => { "in" => [ "cheap-classifier" ] } }, rule.constraints)
    assert_equal({ "per_hour" => 10, "per_day" => 50 }, rule.limits)
    ok = { "surface" => "muse", "since" => "2026-09-01" }
    assert_equal "completed", as(@muse, realm: "household") { Sentinel.submit!(agent: @muse, capability: "hob.usage", arguments: ok) }.status
    assert_equal "denied", as(@muse, realm: "household") { Sentinel.submit!(agent: @muse, capability: "hob.usage", arguments: ok.merge("surface" => "all")) }.status
  end

  test "an error inside the steward leaves the petition referred with the error, not undecided" do
    charter!(@muse, "allow")
    steward_says("grant", capability: "hob.usage", effect: "allow")
    original = Sentinel::Steward.instance_method(:write_rule!)
    Sentinel::Steward.define_method(:write_rule!) { |_v| raise ActiveRecord::RecordInvalid, SentinelPolicy.new }
    begin
      row = petition("see my spend", capability: "hob.usage")
    ensure
      Sentinel::Steward.define_method(:write_rule!, original)
    end
    assert_equal "pending", row.status
    assert_equal "refer", row.action
    assert_equal "steward", row.decided_by
    assert_match(/steward error: RecordInvalid/, row.rationale)
    assert_equal "hob.usage", row.capability_name
    assert_equal 1, @pings.size
  end

  test "grant is refused for what the agent cannot reach, what a rule denies, and what it already has" do
    charter!(@muse, "allow")
    Capability.find_by!(name: "hob.conversation.read").update!(realm: "intimate")
    steward_says("grant", capability: "hob.conversation.read")
    row = petition("read conversations")
    assert_equal "pending", row.status
    assert_equal "refer", row.action
    assert_match(/not grantable/, row.rationale)
    assert_match(/above the agent's clearance.*hob.conversation.read/m, @fake.calls.last.messages.last["content"])
    assert_equal 1, @pings.size
    assert_match(/muse petitions/, @pings.last[1])

    policy!(@muse, "hob.mission.*", "deny")
    steward_says("grant", capability: "hob.mission.create")
    assert_equal "pending", petition("hand out missions").status

    policy!(@muse, "hob.usage", "confirm")
    steward_says("grant", capability: "hob.usage", effect: "allow")
    row = petition("see my usage")
    assert_equal "granted", row.status
    assert_match(/already permitted: confirm/, row.rationale)
    assert_equal "confirm", SentinelPolicy.find_by!(principal: @muse, capability: "hob.usage").effect, "an existing exact rule is kept"
  end

  test "a confirm charter refers everything, with the steward's advice attached" do
    charter!(nil, "confirm")
    steward_says("grant", capability: "hob.usage", effect: "allow", rationale: "harmless")
    row = petition("see my usage")
    assert_equal "pending", row.status
    assert_equal "grant", row.review["verdict"]
    assert_equal "hob.usage", row.capability_name
    assert_equal "allow", row.effect
    assert_match(/refers every petition to a person/, row.rationale)
    assert_nil SentinelPolicy.find_by(principal: @muse, capability: "hob.usage")
  end

  test "build: under an allow charter the steward dispatches a mission to the forge; the PR proposes; sync grants" do
    forge, _token = forge!
    charter!(@muse, "allow", guidance: "Build what Tessa's planning needs.")
    steward_says("build", capability: "hob.calendar.read", effect: "allow", spec: calendar_spec, guidance: "Only Tessa's calendar.",
                 rationale: "nothing reads the calendar yet")

    row = petition("read the household calendar for next week", capability: "hob.calendar.read", arguments: { "from" => "2026-09-21" })
    assert_equal "building", row.status
    assert_equal "build", row.action
    assert_equal "hob.calendar.read", row.capability_name
    assert_equal "allow", row.effect, "a read may be allowed"
    assert_equal "Read the household calendar for a date range.", row.spec["description"]
    assert_equal %w[from], row.spec["input_schema"]["required"]
    assert_equal [ "1. returns events in range", "2. rejects a missing from" ], row.spec["acceptance"]
    assert_equal({ "events" => [] }, row.spec["result"])
    assert_equal "Only Tessa's calendar.", row.spec["guidance"]

    mission = Mission.find(row.mission_id)
    assert_equal forge, mission.assignee
    assert_equal @muse, mission.created_by
    assert_equal "Build capability hob.calendar.read", mission.title
    assert_equal "forge.capability", mission.payload["kind"]
    assert_equal row.id, mission.payload["petition"]
    assert_equal "hob.calendar.read", mission.payload["spec"]["name"]
    assert_equal "household", mission.realm
    assert_match(/forging hob.calendar.read/, @pings.last[1])

    # The forge leases, builds, and reports a PR.
    leased = Mission.lease_next!(forge)
    assert_equal mission, leased
    leased.complete!({ "pull_request" => "https://github.com/x/hob/pull/42", "branch" => "forge/hob-calendar-read" })
    row.reload
    assert_equal "proposed", row.status
    assert_equal "https://github.com/x/hob/pull/42", row.pull_request
    assert_match(/PR ready/, @pings.last[1])
    assert_match(%r{pull/42}, @pings.last[2])

    # Merged and deployed: sync registers the capability and the grant lands.
    Capability.create!(name: "hob.calendar.read", description: "Calendar", kind: "read", realm: "household",
                       venue: "native", config: { "handler" => "usage" })
    row.reload
    assert_equal "granted", row.status
    rule = row.sentinel_policy
    assert_equal "hob.calendar.read", rule.capability
    assert_equal "allow", rule.effect
    assert_equal "Only Tessa's calendar.", rule.guidance
    assert row.settled?
  end

  test "build failures are recorded and a person can retry, deny, or grant instead" do
    forge, _token = forge!
    charter!(@muse, "allow")
    steward_says("build", capability: "hob.calendar.read", spec: calendar_spec)
    row = petition("read the calendar")
    Mission.lease_next!(forge).fail!("tests failed")
    row.reload
    assert_equal "failed", row.status
    assert_match(/tests failed/, row.error)
    assert_match(/build failed/, @pings.last[1])

    assert_raises(Sentinel::Invalid) { Sentinel.decide_petition!(row, decision: "build", decider: @muse) }
    assert_raises(Sentinel::Invalid) { Sentinel.decide_petition!(row, decision: "maybe", decider: @principal) }

    first_mission = row.mission_id
    retried = Sentinel.decide_petition!(row, decision: "build", decider: @principal, rationale: "try again")
    assert_equal "building", retried.status
    assert_equal "human", retried.decided_by
    assert_equal @principal, retried.decider
    assert_not_equal first_mission, retried.mission_id
    assert_equal retried.mission_id, Mission.for(forge).queued.first.id
    assert_equal "hob.calendar.read", Mission.for(forge).queued.first.payload["spec"]["name"]

    Mission.lease_next!(forge).cancel!
    assert_equal "failed", row.reload.status
    denied = Sentinel.decide_petition!(row, decision: "deny", decider: @principal, rationale: "not now")
    assert_equal "denied", denied.status
    assert_equal "not now", denied.rationale
    assert_raises(Sentinel::Invalid) { Sentinel.decide_petition!(row, decision: "deny", decider: @principal) }
  end

  test "build is referred under a review charter, when the day's builds are spent, and without a forge" do
    charter!(@muse, "review")
    steward_says("build", capability: "hob.calendar.read", spec: calendar_spec, rationale: "new")
    row = petition("read the calendar")
    assert_equal "pending", row.status
    assert_match(/a person must approve builds/, row.rationale)
    assert_equal "hob.calendar.read", row.capability_name
    assert_equal "Read the household calendar for a date range.", row.spec["description"], "the spec is kept for the person"

    # A person approves the build from the pending petition — the spec is already there.
    assert_raises(Sentinel::Invalid, "no forge yet") { Sentinel.decide_petition!(row, decision: "build", decider: @principal) }
    forge, _token = forge!
    built = Sentinel.decide_petition!(row, decision: "build", decider: @principal, effect: "review")
    assert_equal "building", built.status
    assert_equal "review", built.effect
    assert_equal "hob.calendar.read", Mission.for(forge).queued.first.payload["spec"]["name"]

    SentinelPolicy.delete_all
    charter!(@muse, "allow", limits: { "builds_per_day" => 1 })
    steward_says("build", capability: "hob.weather.read", spec: calendar_spec)
    assert_equal "pending", (second = petition("weather")).status
    assert_match(/daily build limit/, second.rationale)
    assert_match(/build allowance is used up/, @fake.calls.last.messages.last["content"])
  end

  test "a bad build verdict is referred, not built: an existing name, an invalid name, no spec" do
    forge!
    charter!(@muse, "allow")
    steward_says("build", capability: "hob.usage", spec: calendar_spec)
    assert_match(/already exists; grant it instead/, petition("usage").rationale)
    steward_says("build", capability: "Bad Name", spec: calendar_spec)
    assert_match(/not a valid capability name/, petition("bad").rationale)
    steward_says("build", capability: "hob.thing.do")
    assert_match(/spec is incomplete/, petition("thing").rationale)
    assert Petition.all.all?(&:pending?)
    assert_empty Mission.all
  end

  test "a person grants a pending petition with their own effect, constraints, and guidance" do
    charter!(@muse, "confirm")
    steward_says("refer", rationale: "not sure")
    row = petition("run cheap completions for sorting errands", capability: "hob.complete")
    assert_equal "pending", row.status

    granted = Sentinel.decide_petition!(row, decision: "grant", decider: @principal, capability: "hob.complete", effect: "allow",
                                        constraints: { "role" => [ "cheap-classifier" ] }, limits: { "per_day" => 20 }, guidance: "Errands only.",
                                        rationale: "fine for errands")
    assert_equal "granted", granted.status
    assert_equal "human", granted.decided_by
    rule = granted.sentinel_policy
    assert_equal "allow", rule.effect, "a person may exceed the steward's cap"
    assert_equal({ "role" => { "in" => [ "cheap-classifier" ] } }, rule.constraints, "the array shorthand is normalized")
    assert_equal({ "per_day" => 20 }, rule.limits)
    assert_equal "Errands only.", rule.guidance

    other = petition("read conversations", capability: "hob.conversation.read")
    assert_raises(Sentinel::Invalid) { Sentinel.decide_petition!(other, decision: "grant", decider: @principal, capability: "hob.nope") }
    assert_raises(Sentinel::Invalid) { Sentinel.decide_petition!(other, decision: "grant", decider: @principal, capability: "hob.conversation.read", effect: "sometimes") }
  end

  test "deny by the steward, limits per day, and an unavailable steward refers" do
    charter!(@muse, "allow", limits: { "per_day" => 2 })
    steward_says("deny", rationale: "other people's mail is not yours")
    row = petition("read Jenner's email")
    assert_equal "denied", row.status
    assert_equal "steward", row.decided_by
    assert_equal "other people's mail is not yours", row.rationale

    @fake.fail(Gateway::Unavailable.new("down"))
    down = petition("anything")
    assert_equal "pending", down.status
    assert_match(/steward unavailable/, down.rationale)

    @fake.refuse
    refused = petition("anything else")
    assert_equal "pending", refused.status
    assert_match(/declined to judge/, refused.rationale)

    limited = petition("one more")
    assert_equal "denied", limited.status
    assert_equal "limit", limited.decided_by
    assert_match(/per_day limit of 2 petitions/, limited.rationale)
  end

  test "the brief carries the mission, history, and what the agent already has" do
    charter!(@muse, "allow")
    policy!(@muse, "hob.usage", "allow")
    mission = Mission.create!(assignee: @muse, title: "Plan the week", brief: "Dinners", realm: "household")
    as(@muse, realm: "household") { Sentinel.submit!(agent: @muse, capability: "hob.usage") }
    steward_says("deny", rationale: "no")
    petition("first")
    steward_says("refer", rationale: "hm")
    petition("read the calendar", on_mission: mission.id, arguments: { "week" => 38 })
    content = @fake.calls.last.messages.last["content"]
    assert_match(/working on mission #{mission.id}: Plan the week/, content)
    assert_match(/hob.usage: completed \(policy\)/, content)
    assert_match(/first: deny/, content)
    assert_match(/may already ask for:\n- hob.usage: allow/, content)
    assert_match(/"week": 38/, content)
    assert_no_match(/^- hob.usage — read/, content, "what it already has is not offered to grant")
  end

  test "petitions sit behind RLS like requests" do
    charter!(@muse, "allow")
    steward_says("deny")
    row = petition("x", realm: "household")
    clearance!("household")
    assert Petition.exists?(row.id)
    personal, _t = agent("scribe", clearance: "personal")
    charter!(personal, "allow")
    steward_says("deny")
    private_row = petition("y", agent: personal, realm: "personal")
    clearance!("household")
    assert_not Petition.exists?(private_row.id)
    clearance!("intimate")
    assert Petition.exists?(private_row.id)
  end
end
