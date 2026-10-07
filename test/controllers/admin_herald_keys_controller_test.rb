require "test_helper"
require_relative "../support/fake_herald"

# Changing a herald key's permissions and scope from the admin UI: herald
# faked at the transport (FakeHerald), never a real one (TEXTS.md; herald's
# API.md, "Keys (admin)").
class AdminHeraldKeysControllerTest < ActionDispatch::IntegrationTest
  Herald = Texts::Backends::Herald

  setup do
    admin_signing_in!
    @backend = text_backend("jenner-messages")
    ENV["HOB_TEST_HERALD_KEY"] = FakeHerald::KEY
    ENV["HERALD_ADMIN_TOKEN"] = FakeHerald::ADMIN_TOKEN
    Herald.transport = (@herald = FakeHerald.new).to_proc
    @herald.key("hob")
    @herald.key("hob-family", scope: { "chats" => [ "any;+;chat100" ], "handles" => [ "+15551234567" ] })
  end

  teardown do
    admin_signed_out!
    Herald.transport = nil
    ENV.delete("HOB_TEST_HERALD_KEY")
    ENV.delete("HERALD_ADMIN_TOKEN")
  end

  test "signed out, the herald keys page sends you to sign in" do
    get "/admin/herald_keys"
    assert_redirected_to "/login"
  end

  test "picking a herald lists its keys as herald has them, read with the admin token" do
    admin_sign_in
    get "/admin/herald_keys", params: { backend: "jenner-messages" }
    assert_response :ok
    assert_select "td code", "hob"
    assert_select "td", /any;\+;chat100/
    assert_select "td", "every chat"

    call = @herald.calls.last
    assert_equal [ "GET", "/v1/keys" ], [ call.verb, call.path ]
    assert_equal "Bearer #{FakeHerald::ADMIN_TOKEN}", call.headers["Authorization"], "the admin token, never the row's key"
  end

  test "editing a key prefills the form from herald" do
    admin_sign_in
    get "/admin/herald_keys", params: { backend: "jenner-messages", key_name: "hob-family" }
    assert_select "input[name=key_name][value=hob-family]"
    assert_select "input[type=checkbox][name='permissions[]'][value=read][checked]"
    assert_select "input[type=checkbox][name='permissions[]'][value=send][checked]"
    assert_select "textarea[name=chats]", "any;+;chat100"
    assert_select "textarea[name=handles]", "+15551234567"
    assert_select "input[type=checkbox][name=unscoped][checked]", false
  end

  test "an admin narrows a key, herald sees the admin token and the actor, and it is audited with herald's before" do
    admin_sign_in

    assert_difference -> { HeraldKeyChange.count }, 1 do
      post "/admin/herald_keys", params: { backend: "jenner-messages", key_name: "hob-family", permissions: [ "read" ],
                                           chats: " any;+;chat100 \nany;+;chat200", handles: "", rationale: "no sending for now" }
    end
    follow_redirect!
    assert_select ".flash.notice", /Updated hob-family.*read; chats any;\+;chat100, any;\+;chat200/

    patch = @herald.calls.find { |c| c.verb == "PATCH" }
    assert_equal "/v1/keys/hob-family", patch.path
    assert_equal({ "permissions" => [ "read" ], "scope" => { "chats" => [ "any;+;chat100", "any;+;chat200" ] } }, patch.json)
    assert_equal "Bearer #{FakeHerald::ADMIN_TOKEN}", patch.headers["Authorization"]
    assert_equal "tester", patch.headers["X-Admin-Actor"]

    change = HeraldKeyChange.order(:created_at).last
    assert_equal [ @backend, "hob-family", @principal, "no sending for now" ], [ change.text_backend, change.key_name, change.decider, change.rationale ]
    assert_equal({ "permissions" => %w[read send], "scope" => { "chats" => [ "any;+;chat100" ], "handles" => [ "+15551234567" ] } }, change.key_before)
    assert_equal({ "permissions" => %w[read], "scope" => { "chats" => [ "any;+;chat100", "any;+;chat200" ] } }, change.key_after)
  end

  test "checking every chat with no chats or handles removes the scope" do
    admin_sign_in
    post "/admin/herald_keys", params: { backend: "jenner-messages", key_name: "hob-family", permissions: %w[read send], unscoped: "1" }
    follow_redirect!
    assert_select ".flash.notice", /every chat/
    assert_equal({ "permissions" => %w[read send], "scope" => nil }, @herald.calls.find { |c| c.verb == "PATCH" }.json)
  end

  test "a form hob can tell is wrong never reaches herald, and keeps what was typed" do
    admin_sign_in
    [
      [ { permissions: [], chats: "any;+;chat100" }, /needs a permission/ ],
      [ { permissions: %w[read], chats: "any;+;chat100\n\nany;+;chat200" }, /blank line among the chats/ ],
      [ { permissions: %w[read] }, /every chat/ ],
      [ { permissions: %w[read], chats: "any;+;chat100", unscoped: "1" }, /uncheck/ ]
    ].each do |fields, message|
      assert_no_difference -> { HeraldKeyChange.count } do
        post "/admin/herald_keys", params: { backend: "jenner-messages", key_name: "hob-family" }.merge(fields)
      end
      follow_redirect!
      assert_select ".flash.alert", message
      assert_select "input[name=key_name][value=hob-family]"
    end
    assert_select "input[type=checkbox][name=unscoped][checked]"
    assert_select "textarea[name=chats]", "any;+;chat100"
    assert_empty @herald.calls.select { |c| c.verb == "PATCH" }
  end

  test "herald's refusals surface as human-readable errors, unaudited" do
    admin_sign_in

    post "/admin/herald_keys", params: { backend: "jenner-messages", key_name: "nosuch", permissions: %w[read], unscoped: "1" }
    follow_redirect!
    assert_select ".flash.alert", /no key named nosuch/

    @herald.respond(200, @herald.keys["hob"])
    @herald.respond(422, { "error" => { "code" => "invalid", "message" => "--- is not a phone number or address" } })
    post "/admin/herald_keys", params: { backend: "jenner-messages", key_name: "hob", permissions: %w[read], handles: "---" }
    follow_redirect!
    assert_select ".flash.alert", /refused the change: --- is not a phone number/

    ENV["HERALD_ADMIN_TOKEN"] = "wrong"
    post "/admin/herald_keys", params: { backend: "jenner-messages", key_name: "hob", permissions: %w[read], unscoped: "1" }
    follow_redirect!
    assert_select ".flash.alert", /refused the admin token/

    assert_equal 0, HeraldKeyChange.count
  end

  test "herald unreachable shows an error on the page" do
    admin_sign_in
    Herald.transport = ->(*) { raise Errno::ECONNREFUSED, "connect(2)" }
    get "/admin/herald_keys", params: { backend: "jenner-messages" }
    assert_response :ok
    assert_select ".flash.alert", /Couldn.t read jenner-messages's keys/
  end

  test "no HERALD_ADMIN_TOKEN configured refuses without calling herald" do
    ENV.delete("HERALD_ADMIN_TOKEN")
    admin_sign_in

    post "/admin/herald_keys", params: { backend: "jenner-messages", key_name: "hob", permissions: %w[read], unscoped: "1" }
    follow_redirect!
    assert_select ".flash.alert", /HERALD_ADMIN_TOKEN/
    assert_empty @herald.calls
  end
end
