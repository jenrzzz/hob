require "test_helper"

# Records (RECORDS.md): the contract itself, under the agent's clearance the
# way the sentinel runs it.
class RecordsTest < ActiveSupport::TestCase
  ORDER_SCHEMA = {
    "type" => "object",
    "required" => %w[order_id total],
    "properties" => { "order_id" => { "type" => "string" }, "total" => { "type" => "number" },
                      "items" => { "type" => "array", "items" => { "type" => "object" } } }
  }.freeze

  setup do
    @muse, = agent("muse")
    @orders = Records.create_collection(
      { "name" => "amazon-orders", "key" => "order_id", "description" => "Amazon orders as Muse read them",
        "schema" => ORDER_SCHEMA, "realm" => "household" }, owner: @principal
    )
    @writer = Records::Writer.new(principal: @muse, surface: "gofer", request_id: "req-1", mission_id: "mis-1")
  end

  def order(id = "113-1", total: 64.18, items: [ { "title" => "Car seat", "asin" => "B0SEAT" } ], **extra)
    { "order_id" => id, "total" => total, "items" => items }.merge(extra.stringify_keys)
  end

  def put(data, **attrs)
    Records.put({ "collection" => "amazon-orders", "data" => data }.merge(attrs.stringify_keys), by: @writer)
  end

  test "a put makes a record, keyed by the document's own field, with the request's provenance" do
    result = put(order, links: [ "budget:house-ynab:t-1" ], source: "https://amazon.example/order/113-1")
    record = result["record"]

    assert result["changed"]
    assert_equal "rec:amazon-orders:113-1", record["id"]
    assert_equal [ "113-1", 1, 1 ], record.values_at("key", "version", "schema_version")
    assert_equal [ "budget:house-ynab:t-1" ], record["links"]
    assert_equal({ "principal" => "muse", "surface" => "gofer" }, record["written_by"])

    version = RecordVersion.sole
    assert_equal [ @muse, "gofer", "req-1", "mis-1", "household" ],
                 [ version.principal, version.surface, version.sentinel_request_id, version.mission_id, version.realm ]
  end

  test "a put that changes nothing writes nothing, only that it was seen again; a change is a new version" do
    put(order, observed_at: "2026-09-01T00:00:00Z")
    again = put(order, observed_at: "2026-09-20T00:00:00Z")

    refute again["changed"]
    assert_equal 1, again["record"]["version"]
    assert_equal "2026-09-20T00:00:00Z", again["record"]["observed_at"]
    assert_equal 1, RecordVersion.count, "an unchanged re-scrape does not fill the history"

    changed = put(order(total: 70.0))
    assert changed["changed"]
    assert_equal 2, changed["record"]["version"]
    assert_equal [ 70.0, 64.18 ],
                 Records.history("collection" => "amazon-orders", "key" => "113-1")["versions"].map { |v| v["data"]["total"] }
    assert_equal 64.18, Records.get("collection" => "amazon-orders", "key" => "113-1", "version" => 1).dig("record", "data", "total")
  end

  test "links left out are kept; given, they replace the set" do
    put(order, links: [ "budget:house-ynab:t-1" ])
    assert_equal [ "budget:house-ynab:t-1" ], put(order(total: 1.0))["record"]["links"]
    assert_equal [ "todo:house:9" ], put(order(total: 1.0), links: [ "todo:house:9" ])["record"]["links"]

    error = assert_raises(Records::Invalid) { put(order, links: [ "https://example.com" ]) }
    assert_match(/not a ref/, error.message)
  end

  test "documents must carry the key and meet the schema; unknown attributes are refused" do
    assert_match(/needs "order_id"/, assert_raises(Records::Invalid) { put({ "total" => 1 }) }.message)
    assert_match(/does not meet amazon-orders's schema \(version 1\)/,
                 assert_raises(Records::Invalid) { put(order(total: "lots")) }.message)
    assert_match(/unknown attribute: colour/, assert_raises(Records::Invalid) { put(order, colour: "red") }.message)
    assert_match(/at most 65536/, assert_raises(Records::Invalid) { put(order(note: "x" * 70_000)) }.message)
    assert_match(/no collection named "nope"/,
                 assert_raises(Records::NotFound) { Records.put({ "collection" => "nope", "data" => order }, by: @writer) }.message)
  end

  test "if_version refuses a write against a record that moved on" do
    put(order)
    put(order(total: 2.0))

    conflict = assert_raises(Records::Conflict) { put(order(total: 3.0), if_version: 1) }
    assert_match(/at version 2, not 1/, conflict.message)
    assert_equal 2, conflict.record["version"]
    assert_equal 3, put(order(total: 3.0), if_version: 2)["record"]["version"]
    assert_raises(Records::Conflict) { put(order("113-2"), if_version: 1) }
    assert_equal 1, put(order("113-2"), if_version: 0)["record"]["version"]
  end

  test "put_many is all or nothing, and counts what changed" do
    put(order("113-1"))
    result = Records.put_many({ "collection" => "amazon-orders",
                                "records" => [ { "data" => order("113-1") }, { "data" => order("113-2") } ] }, by: @writer)
    assert_equal [ 1, 1 ], result.values_at("changed", "unchanged")

    error = assert_raises(Records::Invalid) do
      Records.put_many({ "collection" => "amazon-orders",
                         "records" => [ { "data" => order("113-3") }, { "data" => { "order_id" => "113-4" } } ] }, by: @writer)
    end
    assert_match(/records\[1\] does not meet/, error.message)
    refute Record.exists?(key: "113-3"), "the good one did not land either"

    error = assert_raises(Records::Invalid) do
      Records.put_many({ "collection" => "amazon-orders", "records" => [ { "data" => order("9") }, { "data" => order("9") } ] }, by: @writer)
    end
    assert_match(/same key as records\[0\]/, error.message)
  end

  test "query: containment, links, words, times, sort, and a matched count beyond the limit" do
    put(order("a", total: 10.0, items: [ { "title" => "Diapers size 3", "asin" => "B0DIAP" } ]), links: [ "budget:house-ynab:t-a" ])
    put(order("b", total: 30.0, items: [ { "title" => "Car seat", "asin" => "B0SEAT" } ]))
    put(order("c", total: 20.0, items: [ { "title" => "Diapers size 4", "asin" => "B0DIAP4" } ]))

    keys = ->(filters) { Records.query({ "collection" => "amazon-orders" }.merge(filters))["records"].map { |r| r["key"] } }
    assert_equal %w[b], keys.("match" => { "items" => [ { "asin" => "B0SEAT" } ] })
    assert_equal %w[a], keys.("linked" => "budget:house-ynab:t-a")
    assert_equal %w[a c], keys.("q" => "diapers", "sort" => "key")
    assert_equal %w[b c a], keys.("sort" => "-total")
    assert_equal %w[a c b], keys.("sort" => "total")

    result = Records.query("collection" => "amazon-orders", "limit" => 1)
    assert_equal [ 1, 3, true ], result.values_at("count", "matched", "truncated")
    assert_match(/unknown filter: where/, assert_raises(Records::Invalid) { keys.("where" => "1=1") }.message)
    assert_match(/sort must be/, assert_raises(Records::Invalid) { keys.("sort" => "total; DROP TABLE records") }.message)
  end

  test "changes: a cursor that hands out each version once, retractions included" do
    put(order("a"))
    put(order("b"))
    first = Records.changes("collection" => "amazon-orders")
    assert_equal [ %w[a 1], %w[b 1] ], first["changes"].map { |c| [ c["key"], c["version"].to_s ] }

    assert_empty Records.changes("collection" => "amazon-orders", "since" => first["next_since"])["changes"]
    put(order("a")) # unchanged: not a change
    put(order("a", total: 5.0))
    Records.delete({ "collection" => "amazon-orders", "key" => "b", "reason" => "a duplicate" }, by: @writer)

    second = Records.changes("collection" => "amazon-orders", "since" => first["next_since"])
    assert_equal [ [ "a", 2, false ], [ "b", 2, true ] ], second["changes"].map { |c| c.values_at("key", "version", "retracted") }
    assert_equal second["next_since"], Records.changes("collection" => "amazon-orders", "since" => second["next_since"])["next_since"]
    assert_raises(Records::Invalid) { Records.changes("collection" => "amazon-orders", "since" => "garbage!") }
  end

  test "delete retracts: gone from reads, not writable again, restorable, and purged only once retracted" do
    put(order("a"))
    Records.delete({ "collection" => "amazon-orders", "key" => "a", "reason" => "not ours" }, by: @writer)

    assert_raises(Records::NotFound) { Records.get("collection" => "amazon-orders", "key" => "a") }
    assert_empty Records.query("collection" => "amazon-orders")["records"]
    assert_match(/retracted by a person/, assert_raises(Records::Invalid) { put(order("a")) }.message)
    assert_match(/reason is required/,
                 assert_raises(Records::Invalid) { Records.delete({ "collection" => "amazon-orders", "key" => "a" }, by: @writer) }.message)

    record = Record.find_by!(key: "a")
    Records.restore!(record, by: Records::Writer.new(principal: @principal, surface: "admin"), reason: "it was ours")
    assert_equal 64.18, Records.get("collection" => "amazon-orders", "key" => "a").dig("record", "data", "total")
    assert_equal [ 3, 2, 1 ], record.versions.pluck(:version)

    assert_raises(Records::Invalid) { Records.purge!(record.reload) }
    Records.delete({ "collection" => "amazon-orders", "key" => "a", "reason" => "really not ours" }, by: @writer)
    Records.purge!(record.reload)
    assert_equal 0, RecordVersion.count
  end

  test "a retracted collection leaves every read with its records, keeps its name, and comes back whole" do
    put(order("a"))
    result = Records.delete_collection({ "collection" => "amazon-orders", "reason" => "moving" }, by: @writer)
    assert_equal 1, result["records"]

    assert_raises(Records::NotFound) { Records.query("collection" => "amazon-orders") }
    assert_empty Records.collections["collections"]
    assert_match(/already exists/, assert_raises(Records::Invalid) {
      Records.create_collection({ "name" => "amazon-orders", "key" => "id", "description" => "again", "realm" => "household" }, owner: @principal)
    }.message)

    Records.restore_collection!(@orders.reload)
    assert_equal 1, Records.query("collection" => "amazon-orders")["matched"]

    Records.delete_collection({ "collection" => "amazon-orders", "reason" => "done" }, by: @writer)
    Records.purge_collection!(@orders.reload)
    assert_equal [ 0, 0, 0 ], [ RecordCollection.count, Record.count, RecordVersion.count ]
  end

  test "a collection is owned by a person, in a realm the caller can see, with a schema that is one" do
    attrs = { "name" => "costco-receipts", "key" => "receipt_id", "description" => "Costco receipts", "realm" => "household" }
    assert_match(/owned by a person/, assert_raises(Records::Invalid) { Records.create_collection(attrs, owner: @muse) }.message)
    assert_match(/not a valid JSON Schema/, assert_raises(Records::Invalid) {
      Records.create_collection(attrs.merge("schema" => { "type" => "nonsense" }), owner: @principal)
    }.message)
    assert_match(/must be a lowercase slug/, assert_raises(Records::Invalid) {
      Records.create_collection(attrs.merge("name" => "Costco Receipts"), owner: @principal)
    }.message)
    as(@muse, realm: "household") do
      assert_match(/above this request's clearance/, assert_raises(Records::Invalid) {
        Records.create_collection(attrs.merge("realm" => "personal"), owner: @principal, proposed_by: @muse)
      }.message)
      made = Records.create_collection(attrs.except("realm"), owner: @principal, proposed_by: @muse)
      assert_equal [ "household", @principal, @muse ], [ made.realm, made.principal, made.proposed_by ]
    end
  end

  test "a schema change is a new schema_version; records stay as written and are counted when the new schema refuses them" do
    put(order("a"))
    stricter = ORDER_SCHEMA.merge("required" => %w[order_id total shipments])

    result = Records.update_collection("collection" => "amazon-orders", "reason" => "Amazon charges per shipment", "schema" => stricter)
    assert result["changed"]
    assert_equal [ 2, 1 ], [ result.dig("collection", "schema_version"), result["refused"] ]
    assert_equal 1, Records.get("collection" => "amazon-orders", "key" => "a").dig("record", "schema_version")
    assert_raises(Records::Invalid) { put(order("b")) }
    assert_equal 2, put(order("b", shipments: []))["record"]["schema_version"]

    same = Records.update_collection("collection" => "amazon-orders", "reason" => "again", "schema" => stricter)
    refute same["changed"]
    assert_equal 2, same.dig("collection", "schema_version")
    assert_equal 2, Records.update_collection("collection" => "amazon-orders", "reason" => "words", "description" => "Orders")
                           .dig("collection", "schema_version"), "a description is not a schema change"

    assert_match(/unknown attribute: key/, assert_raises(Records::Invalid) {
      Records.update_collection("collection" => "amazon-orders", "reason" => "x", "key" => "id")
    }.message)
    @orders.reload.realm = "personal"
    refute @orders.valid?
  end

  test "RLS: a household request cannot see a personal collection or anything in it" do
    Records.create_collection({ "name" => "gifts", "key" => "order_id", "description" => "Gifts", "realm" => "personal" }, owner: @principal)
    Records.put({ "collection" => "gifts", "data" => order("g") }, by: @writer)

    as(@muse, realm: "household") do
      assert_equal [ "amazon-orders" ], Records.collections["collections"].map { |c| c["name"] }
      assert_raises(Records::NotFound) { Records.query("collection" => "gifts") }
      assert_raises(Records::NotFound) { Records.put({ "collection" => "gifts", "data" => order("h") }, by: @writer) }
      assert_equal 0, Record.where(key: "g").count
      assert_equal 0, RecordVersion.where(realm: "personal").count
    end
  end
end
