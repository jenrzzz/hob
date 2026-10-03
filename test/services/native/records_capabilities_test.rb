require "test_helper"

# records.* (RECORDS.md): how an outside agent keeps what it found. Writing
# into a collection is the agent's to do; making, changing, and removing
# collections and removing records are a person's to approve, whatever the
# household's rules say.
class RecordsCapabilitiesTest < ActiveSupport::TestCase
  READS = %w[records.collections records.get records.query records.history records.changes].freeze
  WRITES = %w[records.put records.put_many].freeze
  PERSON = %w[records.collection.create records.collection.update records.delete records.collection.delete].freeze

  setup do
    native_capabilities!
    @muse, = agent("muse")
    policy!(@muse, "records.*", "allow")
  end

  # Braceless string-keyed arguments arrive in **more (Ruby 3 keywords).
  def submit(capability, arguments = {}, agent: @muse, realm: "household", **more)
    arguments = arguments.merge(more)
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments, reason: "keeping orders") }
  end

  def completed(capability, arguments = {})
    request = submit(capability, arguments)
    assert_equal "completed", request.status, request.error.to_s
    request.result
  end

  # A person-confirmed capability, asked for and then approved by the test's person.
  def confirmed(capability, arguments = {})
    request = submit(capability, arguments)
    assert_equal "pending", request.status, "#{capability} waits for a person"
    Sentinel.decide!(request, decision: "allow", decider: @principal)
    assert_equal "completed", request.status, request.error.to_s
    request.result
  end

  def orders!
    confirmed("records.collection.create", "name" => "amazon-orders", "key" => "order_id",
                                           "description" => "Amazon orders as Muse read them",
                                           "schema" => { "type" => "object", "required" => %w[order_id] })
  end

  test "sync! registers eleven capabilities at household, closed, and marks the four that only a person may approve" do
    caps = Capability.where("name LIKE 'records.%'").index_by(&:name)
    assert_equal (READS + WRITES + PERSON).sort, caps.keys.sort
    assert_equal READS.sort, caps.values.select { |c| c.kind == "read" }.map(&:name).sort
    assert_equal PERSON.sort, caps.values.select(&:requires_person?).map(&:name).sort
    caps.each_value do |cap|
      assert_equal "household", cap.realm
      assert_equal false, cap.input_schema["additionalProperties"], cap.name
      assert cap.description.length > 80, "#{cap.name}: agents read these"
    end
    assert_equal Records::PUT_ATTRIBUTES.sort, caps["records.put"].input_schema["properties"].keys.sort
    assert_equal Records::QUERY_FILTERS.sort, caps["records.query"].input_schema["properties"].keys.sort
    assert_equal Records::CREATE_ATTRIBUTES.sort, caps["records.collection.create"].input_schema["properties"].keys.sort
    assert_equal Records::UPDATE_ATTRIBUTES.sort, caps["records.collection.update"].input_schema["properties"].keys.sort
  end

  test "an allow rule does not let an agent make a collection: a person confirms it and owns it" do
    request = submit("records.collection.create", "name" => "amazon-orders", "key" => "order_id", "description" => "Orders")
    assert_equal [ "pending", "escalate", "policy" ], [ request.status, request.decision, request.decided_by ]
    assert_match(/only a person may approve records.collection.create/, request.rationale)
    assert_equal 0, RecordCollection.count

    Sentinel.decide!(request, decision: "allow", decider: @principal)
    collection = RecordCollection.sole
    assert_equal [ @principal, @muse, request.id, "household" ],
                 [ collection.principal, collection.proposed_by, collection.sentinel_request_id, collection.realm ]
  end

  test "a person can say no, and a deny rule still denies" do
    request = submit("records.collection.create", "name" => "junk", "key" => "id", "description" => "Everything")
    Sentinel.decide!(request, decision: "deny", decider: @principal, rationale: "too vague")
    assert_equal "denied", request.status
    assert_equal 0, RecordCollection.count

    policy!(@muse, "records.collection.create", "deny")
    assert_equal "denied", submit("records.collection.create", "name" => "x", "key" => "id", "description" => "X").status
  end

  test "a rule naming a person-confirmed capability exactly may only confirm or deny it; a glob may not loosen it either" do
    rule = SentinelPolicy.new(principal: @muse, capability: "records.delete", effect: "allow")
    refute rule.valid?
    assert_match(/must be confirm or deny/, rule.errors[:effect].join)
    assert SentinelPolicy.new(principal: @muse, capability: "records.delete", effect: "confirm").valid?

    policy!(nil, "*", "allow")
    other, = agent("skipsy")
    request = submit("records.collection.delete", { "collection" => "nope", "reason" => "x" }, agent: other)
    assert_equal "pending", request.status, "an allow-everything default still leaves it to a person"
  end

  test "a review rule is not a reviewer's call to make either" do
    SentinelPolicy.where(principal: @muse).delete_all
    policy!(@muse, "records.*", "review", guidance: "anything goes")
    request = submit("records.collection.create", "name" => "amazon-orders", "key" => "order_id", "description" => "Orders")
    assert_equal "pending", request.status
    assert_empty @fake.calls, "no reviewer was asked"
  end

  test "writes and reads go straight through, with the request's provenance; a person-confirmed delete retracts" do
    orders!
    put = completed("records.put", "collection" => "amazon-orders", "data" => { "order_id" => "113-1", "total" => 64.18 },
                                   "links" => [ "budget:house-ynab:t-1" ], "source" => "https://amazon.example/113-1")
    assert_equal Records::NOTICE, put["notice"]
    version = RecordVersion.sole
    assert_equal [ @muse, "muse" ], [ version.principal, version.surface ]
    assert_equal SentinelRequest.where(capability: Capability.find_by(name: "records.put")).sole.id, version.sentinel_request_id

    many = completed("records.put_many", "collection" => "amazon-orders",
                                         "records" => [ { "data" => { "order_id" => "113-1", "total" => 64.18 } },
                                                        { "data" => { "order_id" => "113-2" } } ])
    assert_equal [ 1, 1 ], many.values_at("changed", "unchanged")
    assert_equal %w[113-1], completed("records.query", "collection" => "amazon-orders", "linked" => "budget:house-ynab:t-1")["records"].map { |r| r["key"] }
    assert_equal 2, completed("records.changes", "collection" => "amazon-orders")["changes"].size
    assert_equal 1, completed("records.history", "collection" => "amazon-orders", "key" => "113-1")["versions"].size

    confirmed("records.delete", "collection" => "amazon-orders", "key" => "113-2", "reason" => "a test order")
    request = submit("records.get", "collection" => "amazon-orders", "key" => "113-2")
    assert_equal "failed", request.status
    assert_match(/NotFound/, request.error)
  end

  test "a schema change and a collection delete wait for a person, then happen" do
    orders!
    completed("records.put", "collection" => "amazon-orders", "data" => { "order_id" => "a" })

    updated = confirmed("records.collection.update", "collection" => "amazon-orders", "reason" => "shipments",
                                                     "schema" => { "type" => "object", "required" => %w[order_id shipments] })
    assert_equal [ 2, 1 ], [ updated.dig("collection", "schema_version"), updated["refused"] ]

    deleted = confirmed("records.collection.delete", "collection" => "amazon-orders", "reason" => "starting over")
    assert_equal 1, deleted["records"]
    assert_empty completed("records.collections")["collections"]
  end

  test "a bad write fails the request with the reason, and an agent cannot write above its clearance" do
    orders!
    request = submit("records.put", "collection" => "amazon-orders", "data" => { "total" => 1 })
    assert_equal "failed", request.status
    assert_match(/Invalid: data needs "order_id"/, request.error)

    Records.create_collection({ "name" => "gifts", "key" => "id", "description" => "Gifts", "realm" => "personal" }, owner: @principal)
    request = submit("records.put", "collection" => "gifts", "data" => { "id" => "g" })
    assert_match(/NotFound: no collection named "gifts"/, request.error)
  end

  test "a steward granting one of the four grants confirm, even when asked for allow" do
    charter!(@muse, "allow")
    cap = Capability.find_by!(name: "records.delete")
    SentinelPolicy.where(principal: @muse).delete_all
    petition = Petition.create!(principal: @muse, want: "remove orders", surface: "muse", realm: "household")
    verdict = Sentinel::Steward::Verdict.new(action: "grant", capability: cap.name, effect: "allow", rationale: "fine")
    bounded = Sentinel::Steward.new(petition).send(:bound, verdict, human: true)
    assert_equal "confirm", bounded.effect
  end

  test "a person's own assistant over MCP needs no one's confirmation, and owns what it makes" do
    made = as(@principal, realm: "personal") do
      Mcp.call("records_collection_create", "name" => "receipts", "key" => "id", "description" => "Receipts")
    end
    assert_equal [ "personal", "tester" ], made["collection"].values_at("realm", "owner")
    assert_nil RecordCollection.sole.proposed_by

    as(@principal, realm: "personal") { Mcp.call("records_put", "collection" => "receipts", "data" => { "id" => 1 }) }
    assert_equal [ @principal, nil ], [ RecordVersion.sole.principal, RecordVersion.sole.sentinel_request_id ]
    tool = as(@principal, realm: "personal") { Mcp.tools["records_delete"] }
    assert tool.as_json.dig("annotations", "destructiveHint")
  end
end
