require "test_helper"

# /v1/browse_sessions: a surface or a person browses through hob, over the Fake.
class BrowseSessionsControllerTest < ActionDispatch::IntegrationTest
  Fake = Browse::Backends::Fake

  setup do
    browser("mini", config: { "domains" => [ "shop.test" ] })
    @site = Fake.site("mini")
    @site.page("https://shop.test/", title: "Shop", text: "Welcome", links: { "e1" => "https://shop.test/orders", "e2" => "https://elsewhere.test/" })
    @site.page("https://shop.test/orders", title: "Orders", text: "Order 111 $12.34")
  end

  teardown { Fake.reset! }

  test "open, look, step, list, close" do
    post "/v1/browse_sessions", params: { goal: "read the orders for the ledger", url: "https://shop.test/" }, headers: auth, as: :json
    assert_response :created
    id = body["session"]["id"]
    assert_equal "Shop", body["session"]["title"]
    assert_match(/\[ref=e1\]/, body["snapshot"])

    get "/v1/browse_sessions/#{id}", params: { screenshot: 1 }, headers: auth
    assert_response :ok
    assert body["screenshot"].present?

    # The step's `action` is read from the body, not shadowed by the route's.
    post "/v1/browse_sessions/#{id}/actions", params: { action: "click", ref: "e1" }, headers: auth, as: :json
    assert_response :ok, body.to_json
    assert_equal "Orders", body["session"]["title"]
    assert_equal 1, body["session"]["steps"]

    post "/v1/browse_sessions/#{id}/actions", params: { action: "read" }, headers: auth, as: :json
    assert_equal "Order 111 $12.34", body["text"]

    get "/v1/browse_sessions", headers: auth
    assert_equal [ id ], body["sessions"].map { |s| s["id"] }

    delete "/v1/browse_sessions/#{id}", headers: auth
    assert_response :ok
    assert_equal "closed", body["session"]["status"]
    get "/v1/browse_sessions/#{id}", headers: auth
    assert_response :gone
  end

  test "what Browse raises comes back as HTTP" do
    post "/v1/browse_sessions", params: { url: "https://shop.test/" }, headers: auth, as: :json
    assert_response :unprocessable_entity
    assert_match(/goal is required/, body["error"])
    post "/v1/browse_sessions", params: { goal: "read the orders for the ledger", url: "https://elsewhere.test/" }, headers: auth, as: :json
    assert_response :unprocessable_entity
    get "/v1/browse_sessions/nope", headers: auth
    assert_response :not_found

    post "/v1/browse_sessions", params: { goal: "read the orders for the ledger", url: "https://shop.test/" }, headers: auth, as: :json
    id = body["session"]["id"]
    post "/v1/browse_sessions/#{id}/actions", params: { action: "purchase" }, headers: auth, as: :json
    assert_response :unprocessable_entity
    assert_match(/action is one of/, body["error"])

    Fake.fail!("mini", Browse::Unavailable.new("the mini is asleep"))
    post "/v1/browse_sessions/#{id}/actions", params: { action: "reload" }, headers: auth, as: :json
    assert_response :service_unavailable
    assert_equal "unavailable", body["status"]
    Fake.fail!("mini", Browse::Forbidden.new("gofer refused mini's key"))
    post "/v1/browse_sessions/#{id}/actions", params: { action: "reload" }, headers: auth, as: :json
    assert_response :forbidden
    assert_match(/hob's key/, body["error"])
  end

  test "an agent's key gets nothing here; a household key cannot see a personal browser" do
    _muse, token = agent("muse")
    post "/v1/browse_sessions", params: { goal: "read the orders for the ledger", url: "https://shop.test/" },
         headers: { "Authorization" => "Bearer #{token}" }, as: :json
    assert_response :forbidden
    assert_match(/sentinel/, body["error"])

    post "/v1/browse_sessions", params: { goal: "read the orders for the ledger", url: "https://shop.test/" },
         headers: auth("X-Hob-Clearance" => "household"), as: :json
    assert_response :not_found
    assert_match(/no browser is visible/, body["error"])
  end
end
