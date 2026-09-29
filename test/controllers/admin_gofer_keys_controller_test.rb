require "test_helper"

# Editing a gofer key's domains from the admin UI: gofer mocked at the
# transport, never a real gofer (BROWSE.md, "gofer"; API.md, "Key
# management (admin)").
class AdminGoferKeysControllerTest < ActionDispatch::IntegrationTest
  Gofer = Browse::Backends::Gofer

  setup do
    admin_signing_in!
    @browser = browser("mini-chrome", kind: "gofer", config: { "url" => "http://mini.test:8378", "key_env" => "HOB_TEST_GOFER_KEY" })
    ENV["HOB_TEST_GOFER_KEY"] = "browsing-secret"
    ENV["GOFER_ADMIN_TOKEN"] = "admin-secret"
    @calls = []
    @responses = []
    Gofer.transport = lambda do |verb, url, body, headers|
      @calls << [ verb, url, body && JSON.parse(body), headers ]
      @responses.shift || [ 200, { "name" => "hob", "domains" => [] }.to_json ]
    end
  end

  teardown do
    admin_signed_out!
    Gofer.transport = nil
    ENV.delete("HOB_TEST_GOFER_KEY")
    ENV.delete("GOFER_ADMIN_TOKEN")
  end

  test "signed out, the gofer keys page sends you to sign in" do
    get "/admin/gofer_keys"
    assert_redirected_to "/login"
  end

  test "an admin updates a key's domains, gofer sees the admin token (not the browsing key), and it is audited" do
    admin_sign_in
    @responses << [ 200, { "name" => "hob", "domains" => [ "amazon.com", "ynab.com" ] }.to_json ]

    assert_difference -> { GoferKeyChange.count }, 1 do
      post "/admin/gofer_keys", params: { browser: "mini-chrome", key_name: "hob", domains: "Amazon.com\n YNAB.com ", rationale: "widen for bookkeeping" }
    end
    assert_redirected_to %r{/admin/gofer_keys}
    follow_redirect!
    assert_select ".flash.notice", /Updated hob.*amazon\.com, ynab\.com/

    verb, url, body, headers = @calls.last
    assert_equal "PATCH", verb
    assert_equal "http://mini.test:8378/v1/keys/hob", url
    assert_equal({ "domains" => [ "amazon.com", "ynab.com" ] }, body)
    assert_equal "Bearer admin-secret", headers["Authorization"]
    assert_equal "tester", headers["X-Admin-Actor"]

    change = GoferKeyChange.order(:created_at).last
    assert_equal @browser, change.browser
    assert_equal "hob", change.key_name
    assert_equal @principal, change.decider
    assert_nil change.domains_before
    assert_equal [ "amazon.com", "ynab.com" ], change.domains_after
    assert_equal "widen for bookkeeping", change.rationale
  end

  test "checking unrestricted with a blank domains field clears the allowlist" do
    admin_sign_in
    @responses << [ 200, { "name" => "hob", "domains" => [] }.to_json ]

    post "/admin/gofer_keys", params: { browser: "mini-chrome", key_name: "hob", domains: "", unrestricted: "1" }
    follow_redirect!
    assert_select ".flash.notice", /unrestricted/

    assert_equal({ "domains" => [] }, @calls.last[2])
    assert_equal [], GoferKeyChange.order(:created_at).last.domains_after
  end

  test "a later change's domains_before is the previous change's domains_after" do
    admin_sign_in
    @responses << [ 200, { "name" => "hob", "domains" => [ "amazon.com" ] }.to_json ]
    post "/admin/gofer_keys", params: { browser: "mini-chrome", key_name: "hob", domains: "amazon.com" }

    @responses << [ 200, { "name" => "hob", "domains" => [ "ynab.com" ] }.to_json ]
    post "/admin/gofer_keys", params: { browser: "mini-chrome", key_name: "hob", domains: "ynab.com" }

    assert_equal [ "amazon.com" ], GoferKeyChange.order(:created_at).last.domains_before
  end

  test "checking unrestricted with domains typed in is a conflict, and the form keeps what was typed" do
    admin_sign_in

    post "/admin/gofer_keys", params: { browser: "mini-chrome", key_name: "hob", domains: "amazon.com", unrestricted: "1" }
    assert_empty @calls
    follow_redirect!
    assert_select ".flash.alert", /uncheck/
    assert_select "input[name=key_name][value=hob]"
    assert_select "textarea", "amazon.com"
    assert_select "input[type=checkbox][name=unrestricted][checked]"
  end

  test "invalid domains are rejected without ever calling gofer" do
    admin_sign_in

    assert_no_difference -> { GoferKeyChange.count } do
      post "/admin/gofer_keys", params: { browser: "mini-chrome", key_name: "hob", domains: "amazon.com\n\nynab.com" }
    end
    assert_empty @calls
    follow_redirect!
    assert_select ".flash.alert", /blank line/

    assert_no_difference -> { GoferKeyChange.count } do
      post "/admin/gofer_keys", params: { browser: "mini-chrome", key_name: "hob", domains: "" }
    end
    assert_empty @calls
    follow_redirect!
    assert_select ".flash.alert", /unrestricted/
  end

  test "gofer's 400 (invalid), 401 (bad admin credentials) and 404 (unknown key) surface as human-readable errors, unaudited" do
    admin_sign_in

    @responses << [ 400, { "error" => "each domain must be a string" }.to_json ]
    assert_no_difference -> { GoferKeyChange.count } do
      post "/admin/gofer_keys", params: { browser: "mini-chrome", key_name: "hob", domains: "amazon.com" }
    end
    follow_redirect!
    assert_select ".flash.alert", /each domain must be a string/

    @responses << [ 401, { "error" => "unauthorized" }.to_json ]
    post "/admin/gofer_keys", params: { browser: "mini-chrome", key_name: "hob", domains: "amazon.com" }
    follow_redirect!
    assert_select ".flash.alert", /admin credentials/

    @responses << [ 404, { "error" => "no key named nosuch" }.to_json ]
    post "/admin/gofer_keys", params: { browser: "mini-chrome", key_name: "nosuch", domains: "amazon.com" }
    follow_redirect!
    assert_select ".flash.alert", /no key named nosuch/
  end

  test "loading prefills the key name and domains from gofer's own status for that browser's key" do
    admin_sign_in
    @responses << [ 200, { "gofer" => "0.1.0", "browser" => { "running" => true }, "sessions" => 0,
                           "key" => { "name" => "hob", "domains" => [ "amazon.com", "ynab.com" ] } }.to_json ]

    get "/admin/gofer_keys", params: { browser: "mini-chrome", load: 1 }
    assert_response :ok
    assert_select "input[name=key_name][value=hob]"
    assert_select "textarea", /amazon\.com\nynab\.com/

    verb, url, _body, headers = @calls.last
    assert_equal "GET", verb
    assert_equal "http://mini.test:8378/v1/status", url
    assert_equal "Bearer browsing-secret", headers["Authorization"], "loading uses the browsing key, never the admin token"
  end

  test "loading when gofer is unreachable shows an error and leaves the form blank" do
    admin_sign_in
    Gofer.transport = ->(*) { raise Errno::ECONNREFUSED, "connect(2)" }

    get "/admin/gofer_keys", params: { browser: "mini-chrome", load: 1 }
    assert_response :ok
    assert_select ".flash.alert", /Couldn.t read/
  end

  test "no GOFER_ADMIN_TOKEN configured refuses without calling gofer" do
    ENV.delete("GOFER_ADMIN_TOKEN")
    admin_sign_in

    post "/admin/gofer_keys", params: { browser: "mini-chrome", key_name: "hob", domains: "amazon.com" }
    assert_empty @calls
    follow_redirect!
    assert_select ".flash.alert", /GOFER_ADMIN_TOKEN/
  end
end
