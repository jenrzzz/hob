require "test_helper"

# The admin pages: a person signs in through the OIDC provider and manages
# keys; nobody else gets in.
class AdminControllerTest < ActionDispatch::IntegrationTest
  setup { admin_signing_in! }
  teardown { admin_signed_out! }

  test "signed out, admin sends you to sign in; the API is unaffected" do
    get "/admin"
    assert_redirected_to "/login"
    get "/login"
    assert_response :ok
    assert_select "form[action='/auth/oidc']"

    get "/v1/models", headers: auth
    assert_response :ok
  end

  test "a linked person signs in, mints, rotates and revokes keys" do
    admin_sign_in
    assert_redirected_to "/admin"
    follow_redirect!
    assert_response :ok
    assert_select "h2", text: "tester"

    muse, _token = agent("muse")
    post "/admin/principals/#{muse.id}/keys", params: { surface: "phone", clearance: "household" }
    assert_response :ok
    token = css_select(".token").text.strip
    assert_match(/\Ahob_/, token)
    assert_equal "no-store", response.headers["Cache-Control"]
    key = ApiKey.authenticate(token)
    assert_equal [ muse, "phone", "household" ], [ key.principal, key.surface, key.default_clearance ]

    post "/admin/keys/#{key.id}/rotate"
    assert_response :ok
    rotated = css_select(".token").text.strip
    assert_nil ApiKey.authenticate(token), "rotating revokes the old key"
    assert ApiKey.authenticate(rotated)
    assert_equal 1, muse.api_keys.where(surface: "muse").count, "other surfaces' keys are untouched"

    post "/admin/keys/#{ApiKey.authenticate(rotated).id}/revoke"
    assert_redirected_to "/admin#principal-#{muse.id}"
    assert_nil ApiKey.authenticate(rotated)
  end

  test "adding a principal" do
    admin_sign_in
    post "/admin/principals", params: { principal: { name: "marley", kind: "agent", max_clearance: "household" } }
    assert Principal.find_by(name: "marley").agent?
    post "/admin/principals", params: { principal: { name: "marley", kind: "agent", max_clearance: "household" } }
    follow_redirect!
    assert_select ".flash.alert", /taken/
  end

  test "unfreezing an agent after a failed spot-check" do
    admin_sign_in
    skipsy, = agent("skipsy")
    skipsy.freeze_capabilities!(reason: "fabricated claim: \"sure go for it\"")

    get "/admin"
    assert_select "#principal-#{skipsy.id} .tag", "frozen"
    assert_select "#principal-#{skipsy.id}", /fabricated claim/

    post "/admin/principals/#{skipsy.id}/unfreeze"
    assert_redirected_to "/admin#principal-#{skipsy.id}"
    refute skipsy.reload.capabilities_frozen?
  end

  test "an unlinked subject is refused and told how to link" do
    admin_sign_in("sub-stranger")
    assert_response :forbidden
    assert_select ".token", /hob:link\[.*sub-stranger\]/
    get "/admin"
    assert_redirected_to "/login"
  end

  test "an agent linked to a subject still cannot sign in" do
    muse, = agent("muse")
    muse.update_columns(oidc_subject: "sub-muse")
    admin_sign_in("sub-muse")
    assert_response :forbidden
  end

  test "unlinking ends the session; sessions expire" do
    admin_sign_in
    get "/admin"
    assert_response :ok
    @principal.update!(oidc_subject: nil)
    get "/admin"
    assert_redirected_to "/login"

    @principal.update!(oidc_subject: "sub-tester")
    admin_sign_in
    travel Admin::BaseController::SESSION_TTL + 1.minute do
      get "/admin"
      assert_redirected_to "/login"
    end
  end

  test "signing out" do
    admin_sign_in
    post "/logout"
    assert_redirected_to "/login"
    get "/admin"
    assert_redirected_to "/login"
  end
end
