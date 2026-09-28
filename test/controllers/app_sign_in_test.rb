require "test_helper"

# The companion app signs in through the browser: sign in as for /admin,
# confirm, get a one-time code on hob://signed-in, trade it for a key.
class AppSignInTest < ActionDispatch::IntegrationTest
  setup do
    admin_signing_in!
    @verifier = SecureRandom.urlsafe_base64(48)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
  end

  teardown { admin_signed_out! }

  def sign_in_params(**overrides)
    { redirect_uri: "hob://signed-in", state: "st4te", code_challenge: @challenge, code_challenge_method: "S256",
      device: "Jenner's iPhone" }.merge(overrides)
  end

  # Confirm in the browser; -> the code from the hob:// redirect.
  def confirm!
    post "/app/sign_in", params: sign_in_params
    location = URI(response.location)
    assert_equal [ "hob", "signed-in" ], [ location.scheme, location.host ]
    query = Rack::Utils.parse_query(location.query)
    assert_equal "st4te", query["state"]
    query.fetch("code")
  end

  test "signed out, the app's link goes through sign-in and comes back to confirm" do
    get "/app/sign_in", params: sign_in_params
    assert_redirected_to "/login"
    admin_sign_in
    location = URI(response.location)
    assert_equal "/app/sign_in", location.path
    assert_equal sign_in_params.stringify_keys, Rack::Utils.parse_query(location.query)
    follow_redirect!
    assert_response :ok
    assert_select "h1", /Sign in the Hob app/
    assert_select "strong", "Jenner's iPhone"
  end

  test "confirm, trade the code for a key, and the key works; again on the same device replaces it" do
    admin_sign_in
    code = confirm!
    post "/v1/app_sessions", params: { code: code, code_verifier: @verifier }, as: :json
    assert_response :created
    assert_equal [ "tester", "app:Jenner's iPhone", "intimate" ], body.values_at("principal", "surface", "clearance")
    first = body["key"]
    get "/v1/devices", headers: { "Authorization" => "Bearer #{first}" }
    assert_response :ok

    post "/v1/app_sessions", params: { code: code, code_verifier: @verifier }, as: :json
    assert_response :bad_request
    assert_match(/already used/, body["error"])

    post "/v1/app_sessions", params: { code: confirm!, code_verifier: @verifier }, as: :json
    assert_response :created
    assert_nil ApiKey.authenticate(first), "signing in again on the device revokes its old key"
    assert_equal 1, @principal.api_keys.where(surface: "app:Jenner's iPhone").count
  end

  test "a wrong verifier spends the code" do
    admin_sign_in
    code = confirm!
    post "/v1/app_sessions", params: { code: code, code_verifier: "not-it" }, as: :json
    assert_response :bad_request
    assert_match(/verifier/, body["error"])
    post "/v1/app_sessions", params: { code: code, code_verifier: @verifier }, as: :json
    assert_response :bad_request
  end

  test "an expired code is refused" do
    admin_sign_in
    code = confirm!
    travel SignInGrant::TTL + 1.second do
      post "/v1/app_sessions", params: { code: code, code_verifier: @verifier }, as: :json
      assert_response :bad_request
      assert_match(/expired/, body["error"])
    end
  end

  test "cancel goes back to the app with no code" do
    admin_sign_in
    post "/app/sign_in", params: sign_in_params(cancel: "1")
    query = Rack::Utils.parse_query(URI(response.location).query)
    assert_equal({ "error" => "access_denied", "state" => "st4te" }, query)
    assert_equal 0, SignInGrant.count
  end

  test "only hob://signed-in, S256 and a well-formed challenge are accepted" do
    admin_sign_in
    [ { redirect_uri: "https://evil.example/cb" }, { redirect_uri: "hob://signed-in.evil" }, { code_challenge_method: "plain" },
      { code_challenge: "short" }, { state: "" } ].each do |bad|
      post "/app/sign_in", params: sign_in_params(**bad)
      assert_response :bad_request, bad.inspect
    end
    assert_equal 0, SignInGrant.count
  end
end
