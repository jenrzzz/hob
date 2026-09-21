require "test_helper"

# The companion app registers its phone with a person's key and can ring it.
class DevicesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @sent = []
    Push.transport = ->(device, note) { @sent << [ device, note ]; [ "200", nil ] }
  end

  teardown { Push.transport = nil }

  test "register, re-register, list, ping, forget" do
    token = "AB" * 32
    post "/v1/devices", params: { token: token, environment: "sandbox", name: "Jenner's iPhone", app_version: "0.1.0" }, headers: auth, as: :json
    assert_response :created
    assert_equal token.downcase, body["token"]
    assert_equal "sandbox", body["environment"]
    assert_equal "Jenner's iPhone", body["name"]
    assert_equal false, body["push_configured"]
    id = body["id"]

    post "/v1/devices", params: { token: token, environment: "production", name: "Jenner's iPhone" }, headers: auth, as: :json
    assert_response :created
    assert_equal id, body["id"], "the same token is the same device"
    assert_equal "production", body["environment"]

    get "/v1/devices", headers: auth
    assert_equal [ id ], body.map { |d| d["id"] }

    post "/v1/devices/#{token}/ping", headers: auth
    assert_response :ok
    assert body["sent"]
    assert_equal "hob", @sent.last.last[:title]
    assert_nil @sent.last.last[:hob]

    Push.transport = ->(*) { [ "410", "Unregistered" ] }
    post "/v1/devices/#{token}/ping", headers: auth
    assert_response :gone
    assert_match(/dead/, body["error"])
    get "/v1/devices", headers: auth
    assert_empty body

    post "/v1/devices", params: { token: token, environment: "sandbox" }, headers: auth, as: :json
    delete "/v1/devices/#{token}", headers: auth
    assert_response :no_content
    get "/v1/devices", headers: auth
    assert_empty body
    delete "/v1/devices/#{token}", headers: auth
    assert_response :not_found
  end

  test "ping without APNs configured says so; a bad token is 422" do
    Push.transport = nil
    post "/v1/devices", params: { token: "cd" * 32, environment: "sandbox" }, headers: auth, as: :json
    post "/v1/devices/#{'cd' * 32}/ping", headers: auth
    assert_response :service_unavailable
    assert_match(/APNS_KEY/, body["error"])

    ENV["APNS_KEY"] = "-----BEGIN PRIVATE KEY-----\nnot a key\n-----END PRIVATE KEY-----"
    ENV["APNS_KEY_ID"] = "KEY1234567"
    ENV["APNS_TEAM_ID"] = "TEAM123456"
    post "/v1/devices/#{'cd' * 32}/ping", headers: auth
    assert_response :service_unavailable
    assert_match(/APNS_KEY is not a PEM private key/, body["error"])
    %w[APNS_KEY APNS_KEY_ID APNS_TEAM_ID].each { |k| ENV.delete(k) }

    post "/v1/devices", params: { token: "not hex", environment: "sandbox" }, headers: auth, as: :json
    assert_response :unprocessable_entity
    post "/v1/devices", params: { token: "ef" * 32, environment: "staging" }, headers: auth, as: :json
    assert_response :unprocessable_entity
  end

  test "only a person's key registers a phone" do
    _muse, agent_token = agent("muse")
    post "/v1/devices", params: { token: "ab" * 32, environment: "sandbox" }, headers: { "Authorization" => "Bearer #{agent_token}" }, as: :json
    assert_response :forbidden

    surface = Principal.create!(name: "mise", kind: "surface", max_clearance: "household")
    surface_token = ApiKey.issue!(principal: surface, surface: "mise", default_clearance: "household")
    post "/v1/devices", params: { token: "ab" * 32, environment: "sandbox" }, headers: { "Authorization" => "Bearer #{surface_token}" }, as: :json
    assert_response :forbidden
    assert_equal 0, Device.count
  end
end
