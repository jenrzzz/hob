require "test_helper"

# What the household's agents keep, from the admin pages (RECORDS.md): the
# records.* requests only a person may approve, shown as what they would
# do, and restoring and purging what was retracted.
class AdminRecordsControllerTest < ActionDispatch::IntegrationTest
  setup do
    admin_signing_in!
    native_capabilities!
    @muse, @agent_token = agent("muse")
    policy!(@muse, "records.*", "allow")
    Notify.transport = ->(*) { }
    @orders = Records.create_collection(
      { "name" => "amazon-orders", "key" => "order_id", "description" => "Amazon orders", "realm" => "household",
        "schema" => { "type" => "object", "required" => %w[order_id] } }, owner: @principal
    )
    @writer = Records::Writer.new(principal: @muse, surface: "gofer")
    Records.put({ "collection" => "amazon-orders", "data" => { "order_id" => "113-1", "total" => 64.18 } }, by: @writer)
  end

  teardown do
    admin_signed_out!
    Notify.transport = nil
  end

  def ask(capability, arguments)
    post "/v1/sentinel/requests", params: { capability: capability, arguments: arguments, reason: "tidying" },
         headers: { "Authorization" => "Bearer #{@agent_token}" }, as: :json
    assert_equal "pending", body["status"], body.to_s
    SentinelRequest.find(body["id"])
  end

  test "a proposed schema change shows both schemas and how many records the new one refuses" do
    request = ask("records.collection.update", collection: "amazon-orders", reason: "per shipment",
                                               schema: { type: "object", required: %w[order_id shipments] })
    admin_sign_in
    get "/admin/sentinel"
    assert_response :ok
    assert_select "#request-#{request.id}", /version 1 → 2/
    assert_select "#request-#{request.id}", /1 of the current records/
    assert_select "#request-#{request.id} pre", /shipments/
  end

  test "a proposed collection, a record delete, and a collection delete each say what they would do" do
    create = ask("records.collection.create", name: "costco-receipts", key: "receipt_id", description: "Costco receipts")
    delete = ask("records.delete", collection: "amazon-orders", key: "113-1", reason: "a test order")
    drop = ask("records.collection.delete", collection: "amazon-orders", reason: "starting over")
    admin_sign_in
    get "/admin/sentinel"
    assert_select "#request-#{create.id}", /New collection\s*costco-receipts, in household; you would own it/
    assert_select "#request-#{delete.id} pre", /64.18/
    assert_select "#request-#{drop.id}", /all\s*1\s*records/

    post "/admin/sentinel/requests/#{create.id}/decide", params: { decision: "allow" }
    assert_equal @principal, RecordCollection.find_by!(name: "costco-receipts").principal
  end

  test "the records page lists collections; a retracted record is restored, or purged for good" do
    Records.delete({ "collection" => "amazon-orders", "key" => "113-1", "reason" => "a test order" }, by: @writer)
    record = Record.sole
    admin_sign_in

    get "/admin/records"
    assert_response :ok
    assert_select "td", /amazon-orders/
    assert_select "td", "a test order"

    post "/admin/records/r/#{record.id}/restore"
    assert_redirected_to "/admin/records/amazon-orders"
    refute record.reload.retracted?
    assert_equal [ "tester", "admin" ], [ record.versions.first.principal.name, record.versions.first.surface ]

    post "/admin/records/r/#{record.id}/purge"
    assert_match(/retract .* before purging/, flash[:alert])
    Records.delete({ "collection" => "amazon-orders", "key" => "113-1", "reason" => "really" }, by: @writer)
    post "/admin/records/r/#{record.id}/purge"
    assert_equal [ 0, 0 ], [ Record.count, RecordVersion.count ]
  end

  test "a retracted collection is restored, and purged only when its name is typed" do
    Records.delete_collection({ "collection" => "amazon-orders", "reason" => "x" }, by: @writer)
    admin_sign_in
    get "/admin/records/amazon-orders"
    assert_response :ok
    assert_select "p", /Retracted/

    post "/admin/records/amazon-orders/purge", params: { confirm_name: "nope" }
    assert RecordCollection.exists?(name: "amazon-orders")
    post "/admin/records/amazon-orders/purge", params: { confirm_name: "amazon-orders" }
    assert_equal [ 0, 0, 0 ], [ RecordCollection.count, Record.count, RecordVersion.count ]
  end

  test "restoring a collection brings its records back" do
    Records.delete_collection({ "collection" => "amazon-orders", "reason" => "x" }, by: @writer)
    admin_sign_in
    post "/admin/records/amazon-orders/restore"
    assert_redirected_to "/admin/records/amazon-orders"
    assert_equal 1, Records.query("collection" => "amazon-orders")["matched"]
  end

  test "signed out, the records page sends you to sign in" do
    get "/admin/records"
    assert_redirected_to "/login"
  end
end
