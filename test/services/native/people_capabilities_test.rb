require "test_helper"

# people.* (PEOPLE.md): how an outside agent reads and keeps the Rolodex.
# Reading, adding people, and writing about them are the agent's to do;
# attaching a handle, merging, and dismissing a loop are a person's to
# approve, whatever the household's rules say.
class PeopleCapabilitiesTest < ActiveSupport::TestCase
  READS = %w[people.list people.get people.loops people.groups].freeze
  WRITES = %w[people.create people.update people.record people.note people.loop.snooze].freeze
  PERSON = %w[people.handle.add people.merge people.loop.dismiss].freeze

  setup do
    native_capabilities!
    @muse, = agent("muse")
    policy!(@muse, "people.*", "allow")
  end

  # Braceless string-keyed arguments arrive in **more (Ruby 3 keywords).
  def submit(capability, arguments = {}, agent: @muse, realm: "household", **more)
    arguments = arguments.merge(more)
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments, reason: "keeping up") }
  end

  def completed(capability, arguments = {}, **more)
    request = submit(capability, arguments, **more)
    assert_equal "completed", request.status, request.error.to_s
    request.result
  end

  test "sync! registers twelve capabilities at household, closed, and marks the three only a person may approve" do
    caps = Capability.where("name LIKE 'people.%'").index_by(&:name)
    assert_equal (READS + WRITES + PERSON).sort, caps.keys.sort
    assert_equal READS.sort, caps.values.select { |c| c.kind == "read" }.map(&:name).sort
    assert_equal PERSON.sort, caps.values.select(&:requires_person?).map(&:name).sort
    caps.each_value do |cap|
      assert_equal "household", cap.realm
      assert_equal false, cap.input_schema["additionalProperties"], cap.name
      assert cap.description.length > 80, "#{cap.name}: agents read these"
    end
    assert_equal People::LIST_FILTERS.sort, caps["people.list"].input_schema["properties"].keys.sort
    assert_equal People::LOOP_FILTERS.sort, caps["people.loops"].input_schema["properties"].keys.sort
    assert_equal People::CREATE_ATTRIBUTES.sort, caps["people.create"].input_schema["properties"].keys.sort
    assert_equal People::UPDATE_ATTRIBUTES.sort, caps["people.update"].input_schema["properties"].keys.sort
    assert_equal People::RECORD_ATTRIBUTES.sort, caps["people.record"].input_schema["properties"].keys.sort
    assert_equal People::MERGE_ATTRIBUTES.sort, caps["people.merge"].input_schema["properties"].keys.sort
    assert_equal People::DISMISS_ATTRIBUTES.sort, caps["people.loop.dismiss"].input_schema["properties"].keys.sort
    assert_equal People::HANDLE_ATTRIBUTES.sort, caps["people.handle.add"].input_schema["properties"].keys.sort
  end

  test "an agent adds a person, records a call, notes something, and reads the brief, all under its own name" do
    person = completed("people.create", "display_name" => "Tara", "handles" => [ "+15550002222" ], "circles" => [ "neighbors" ])["person"]
    assert_equal "household", person["realm"]
    recorded = completed("people.record", "person" => "+15550002222", "kind" => "met", "direction" => "mutual",
                                          "channel" => "in_person", "loop" => { "kind" => "owed_action", "summary" => "ADU photos" })
    assert_equal [ "agent", "muse", "muse" ], recorded["event"]["source"].values_at("kind", "by", "surface")
    assert_equal SentinelRequest.where(capability: Capability.find_by(name: "people.record")).sole.id,
                 PeopleEvent.sole.sentinel_request_id
    completed("people.note", "person" => person["id"], "body" => "Next door; has a ladder")

    brief = completed("people.get", "person" => person["id"])
    assert_equal [ "owed_action" ], brief["open_loops"].map { |l| l["kind"] }
    assert_equal [ "muse" ], brief["notes"].map { |n| n.dig("by", "principal") }
    assert_equal [ "neighbors" ], completed("people.groups")["groups"].map { |g| g["name"] }
    assert completed("people.loops")["notice"]
  end

  test "a merge waits for a person under an allow rule, and runs as the person who said yes" do
    a = completed("people.create", "display_name" => "Eugene", "handles" => [ "+15550001111" ])["person"]
    b = completed("people.create", "display_name" => "Eugene (new)", "handles" => [ "+15559990000" ])["person"]
    request = submit("people.merge", "into" => a["id"], "from" => b["id"], "reason" => "the new number said so")
    assert_equal [ "pending", "escalate" ], [ request.status, request.decision ]
    assert_match(/only a person may approve people.merge/, request.rationale)
    assert_nil Person.find(b["id"]).merged_into_id

    Sentinel.decide!(request, decision: "allow", decider: @principal)
    assert_equal "completed", request.status, request.error.to_s
    assert_equal a["id"], Person.find(b["id"]).merged_into_id
  end

  test "a handle and a dismissal wait for a person too; a dismissal's event names who decided" do
    person = completed("people.create", "display_name" => "Eugene", "handles" => [ "+15550001111" ])["person"]
    request = submit("people.handle.add", "person" => person["id"], "handle" => "eugene@example.com", "reason" => "his signature")
    assert_equal "pending", request.status
    Sentinel.decide!(request, decision: "allow", decider: @principal)
    assert_equal %w[+15550001111 eugene@example.com], Person.find(person["id"]).handles.map(&:address).sort

    loop = completed("people.record", "person" => person["id"], "kind" => "reached_out", "direction" => "inbound",
                                      "channel" => "text")["opened"].sole
    request = submit("people.loop.dismiss", "loop" => loop["id"], "reason" => "a thumbs-up, not a question")
    assert_equal "pending", request.status
    Sentinel.decide!(request, decision: "allow", decider: @principal)
    assert_equal "dismissed", PeopleLoop.find(loop["id"]).state
    assert_equal @principal, PeopleEvent.find_by(kind: "dismissed").recorded_by
  end

  test "what a household agent cannot see does not exist for it" do
    secret = Clearance.with("intimate") do
      Person.create!(display_name: "Someone", realm: "personal").tap do |p|
        p.handles.create!(kind: "phone", address: "+15558887777", realm: "personal")
      end
    end
    request = submit("people.get", "person" => secret.id)
    assert_equal "failed", request.status
    assert_match(/no person/, request.error)
    assert_empty completed("people.list")["people"]
  end

  test "a person's own assistant gets them as MCP tools" do
    names = Current.set(clearance: "personal") { Mcp.tools.keys }
    assert_includes names, "people_get"
    assert_includes names, "people_merge"
    result = Current.set(principal: @principal, clearance: "personal", surface: "claude-code") do
      Mcp.call("people_create", "display_name" => "Ana", "handles" => [ "ana@example.com" ])
    end
    assert_equal [ "Ana", "tester", "personal" ], result["person"].values_at("display_name", "whose", "realm")
  end
end
