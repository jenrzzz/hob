require "test_helper"

# /v1/browsers: a person registers a browser. The key goes in and never
# comes back out.
class BrowsersControllerTest < ActionDispatch::IntegrationTest
  Gofer = Browse::Backends::Gofer

  setup do
    ENV["HOB_TEST_GOFER_KEY"] = "gofer-secret"
    @calls = []
    @responses = []
    Gofer.transport = lambda do |verb, url, _body, headers|
      @calls << [ verb, url, headers["Authorization"] ]
      @responses.shift || [ 200, { "gofer" => "0.1.0", "browser" => { "running" => true, "version" => "141.0" }, "sessions" => 0,
                                   "limits" => { "sessions" => 4 }, "key" => { "name" => "hob", "domains" => [ "amazon.com" ] } }.to_json ]
    end
  end

  teardown do
    Gofer.transport = nil
    Browse::Backends::Fake.reset!
    ENV.delete("HOB_TEST_GOFER_KEY")
  end

  test "a person registers, reads, updates, checks, and forgets a browser; the key is never shown" do
    post "/v1/browsers", params: { name: "mini-chrome", kind: "gofer", realm: "personal",
                                   config: { url: "http://mini.test:8378", key: "inline-secret", addr: "100.64.0.7", domains: [ "amazon.com" ] } },
         headers: auth, as: :json
    assert_response :created
    assert_equal [ "mini-chrome", "gofer", "personal", "tester", true ], body.values_at("name", "kind", "realm", "owner", "enabled")
    assert_equal({ "url" => "http://mini.test:8378", "addr" => "100.64.0.7", "domains" => [ "amazon.com" ], "key" => "set" }, body["config"])
    refute_includes response.body, "inline-secret"

    get "/v1/browsers", headers: auth
    assert_equal %w[mini-chrome], body.map { |b| b["name"] }
    refute_includes response.body, "inline-secret"

    post "/v1/browsers/mini-chrome/check", headers: auth
    assert_response :ok
    assert_equal [ "mini-chrome", true, "0.1.0", "141.0" ], [ body["browser"], body["reachable"], body["gofer"], body.dig("driver", "version") ]
    assert_equal [ "GET", "http://mini.test:8378/v1/status", "Bearer inline-secret" ], @calls.last

    patch "/v1/browsers/mini-chrome", params: { config: { key_env: "HOB_TEST_GOFER_KEY", addr: nil }, enabled: false }, headers: auth, as: :json
    assert_response :ok
    assert_equal({ "url" => "http://mini.test:8378", "key_env" => "HOB_TEST_GOFER_KEY", "domains" => [ "amazon.com" ] }, body["config"])
    assert_equal false, body["enabled"]
    assert_equal "gofer-secret", Browser.find_by!(name: "mini-chrome").key

    @responses << [ 401, { "error" => "unauthorized" }.to_json ]
    post "/v1/browsers/mini-chrome/check", headers: auth
    assert_response :ok, "unreachable is an answer"
    assert_equal false, body["reachable"]
    assert_match(/refused mini-chrome's key/, body["error"])

    delete "/v1/browsers/mini-chrome", headers: auth
    assert_response :no_content
    get "/v1/browsers/mini-chrome", headers: auth
    assert_response :not_found
  end

  test "bad rows are refused; browsers are a person's to manage, and realm-scoped" do
    post "/v1/browsers", params: { name: "x", kind: "gofer", config: { url: "nope" } }, headers: auth, as: :json
    assert_response :unprocessable_entity
    assert_match(/needs a url/, body["error"])
    post "/v1/browsers", params: { name: "x", kind: "gofer", realm: "personal", config: { url: "http://mini.test", key: "k" } },
         headers: auth("X-Hob-Clearance" => "household"), as: :json
    assert_response :unprocessable_entity, "a realm above the clearance"

    browser("house", realm: "household")
    browser("mine", realm: "personal")
    mise = Principal.create!(name: "mise", kind: "surface", max_clearance: "household")
    surface = { "Authorization" => "Bearer #{ApiKey.issue!(principal: mise, surface: 'mise', default_clearance: 'household')}" }
    get "/v1/browsers", headers: surface
    assert_response :forbidden
    get "/v1/browsers", headers: auth("X-Hob-Clearance" => "household")
    assert_equal %w[house], body.map { |b| b["name"] }
    get "/v1/browsers/mine", headers: auth("X-Hob-Clearance" => "household")
    assert_response :not_found
    post "/v1/browsers", params: { name: "mine", kind: "fake" }, headers: auth("X-Hob-Clearance" => "household"), as: :json
    assert_response :unprocessable_entity
    assert_match(/already been taken/, body["error"])
  end
end
