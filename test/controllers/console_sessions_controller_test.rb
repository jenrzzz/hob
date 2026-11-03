require "test_helper"

# /v1/consoles and /v1/console_sessions: a person looks at what is open on
# the household's KVMs, and closes it. Agents use console.* instead.
class ConsoleSessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    kvm("jenner-mac", machine: "Jenner's MacBook")
    @muse, @muse_token = agent("muse", clearance: "personal")
    @id = as(@muse, realm: "personal") { Consoles.open(goal: "turn off Focus mode on the Mac")["session"]["id"] }
  end

  teardown { Consoles::Backends::Fake.reset! }

  test "a person lists, looks, and closes an agent's session" do
    get "/v1/console_sessions", headers: auth
    assert_response :ok
    assert_equal [ @id ], body["sessions"].map { |s| s["id"] }

    get "/v1/console_sessions/#{@id}", headers: auth
    assert_equal "muse", body["session"]["opened_by"]

    get "/v1/console_sessions/#{@id}", params: { screen: 1 }, headers: auth
    assert_response :ok
    assert body["screen"]["data"].present?
    assert_equal Consoles::NOTICE, body["notice"]

    delete "/v1/console_sessions/#{@id}", headers: auth
    assert_response :ok
    assert_equal "closed", body["session"]["status"]

    get "/v1/console_sessions/#{@id}", params: { screen: 1 }, headers: auth
    assert_response :gone
  end

  test "consoles: listed with the key masked, and checked" do
    get "/v1/consoles", headers: auth
    assert_equal [ "jenner-mac" ], body.map { |c| c["name"] }
    post "/v1/consoles/jenner-mac/check", headers: auth
    assert_equal true, body["reachable"]
    Consoles::Backends::Fake.fail!("jenner-mac", Consoles::Unavailable.new("the bridge is down"))
    post "/v1/consoles/jenner-mac/check", headers: auth
    assert_equal({ "console" => "jenner-mac", "reachable" => false, "error" => "the bridge is down" }, body)
  end

  test "an agent's key gets 403" do
    get "/v1/console_sessions", headers: { "Authorization" => "Bearer #{@muse_token}" }
    assert_response :forbidden
    delete "/v1/console_sessions/#{@id}", headers: { "Authorization" => "Bearer #{@muse_token}" }
    assert_response :forbidden
    get "/v1/consoles", headers: { "Authorization" => "Bearer #{@muse_token}" }
    assert_response :forbidden
  end
end
