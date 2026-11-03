require "test_helper"

# Consoles::Backends::Jetkvm: what hob sends the bridge and what it makes of
# the answers (KVM.md, "The bridge"), with the wire stubbed.
class ConsoleJetkvmTest < ActiveSupport::TestCase
  Jetkvm = Consoles::Backends::Jetkvm

  STATE = { "id" => "b1", "expires_at" => "2026-11-03T12:05:00Z",
            "video" => { "ready" => true, "width" => 1920, "height" => 1080, "fps" => 60 },
            "screen" => { "data" => "iVBORw0K", "mime_type" => "image/png", "width" => 1280, "height" => 720 } }.freeze

  setup do
    ENV["HOB_TEST_KVM_KEY"] = "bridge-secret"
    @row = kvm("jenner-mac", kind: "jetkvm", config: { "url" => "http://bridge.test:8379/", "key_env" => "HOB_TEST_KVM_KEY", "addr" => "100.64.0.9" })
    @calls = []
    @responses = []
    Jetkvm.transport = lambda do |verb, url, body, headers|
      @calls << [ verb, url, body && JSON.parse(body), headers ]
      @responses.shift || [ 200, STATE.to_json ]
    end
  end

  teardown do
    Jetkvm.transport = nil
    ENV.delete("HOB_TEST_KVM_KEY")
  end

  def adapter
    @row.adapter
  end

  test "open, state, act, close, check hit the bridge's paths with the key" do
    assert_equal STATE, adapter.open(ttl: 300, scale: nil)
    verb, url, body, headers = @calls.last
    assert_equal [ "POST", "http://bridge.test:8379/v1/sessions", { "ttl" => 300 } ], [ verb, url, body ]
    assert_equal "Bearer bridge-secret", headers["Authorization"]

    adapter.state("b1", scale: 1920)
    assert_equal [ "GET", "http://bridge.test:8379/v1/sessions/b1?screen=1&scale=1920", nil ], @calls.last.first(3)
    adapter.act("b1", { "action" => "key", "key" => "Return" })
    assert_equal [ "POST", "http://bridge.test:8379/v1/sessions/b1/actions", { "action" => "key", "key" => "Return" } ], @calls.last.first(3)
    @responses << [ 204, "" ]
    assert adapter.close("b1")
    assert_equal [ "DELETE", "http://bridge.test:8379/v1/sessions/b1" ], @calls.last.first(2)
    @responses << [ 200, { "bridge" => "0.1.0", "device" => { "version" => "0.5.10", "video" => { "ready" => true } } }.to_json ]
    assert_equal({ "reachable" => true, "bridge" => "0.1.0", "device" => { "version" => "0.5.10", "video" => { "ready" => true } } }, adapter.check)
    assert_equal "http://bridge.test:8379/v1/status", @calls.last[1], "a check connects nothing unless asked"
    @responses << [ 200, {}.to_json ]
    adapter.check(probe: true)
    assert_equal "http://bridge.test:8379/v1/status?probe=1", @calls.last[1]
  end

  test "the bridge's errors map to ours" do
    { 404 => Consoles::NotFound, 410 => Consoles::Gone, 400 => Consoles::Invalid, 422 => Consoles::Invalid,
      401 => Consoles::Forbidden, 403 => Consoles::Forbidden, 409 => Consoles::Unavailable, 429 => Consoles::Unavailable,
      500 => Consoles::Unavailable, 503 => Consoles::Unavailable }.each do |status, error|
      @responses << [ status, { "error" => "no" }.to_json ]
      assert_raises(error, status.to_s) { adapter.act("b1", { "action" => "screenshot" }) }
    end
    Jetkvm.transport = ->(*) { raise Errno::ECONNREFUSED }
    assert_match(/unreachable at bridge.test/, assert_raises(Consoles::Unavailable) { adapter.check }.message)
  end

  test "no key in the environment is unavailable, and says which variable" do
    ENV.delete("HOB_TEST_KVM_KEY")
    assert_match(/HOB_TEST_KVM_KEY is not set/, assert_raises(Consoles::Unavailable) { adapter.check }.message)
  end

  test "config is checked, and the key never comes out" do
    row = Console.new(name: "x", kind: "jetkvm", realm: "personal", principal: @principal, config: { "url" => "nope", "key" => "k", "key_env" => "K", "password" => "p" })
    refute row.valid?
    messages = row.errors[:config].join(" | ")
    assert_match(/unknown keys password/, messages)
    assert_match(/needs a url/, messages)
    assert_match(/not both/, messages)
    shown = kvm("other", kind: "jetkvm", config: { "url" => "http://bridge.test", "key" => "secret" }).as_json
    assert_equal "set", shown["config"]["key"]
    refute_match(/secret/, shown.to_json)
    agent_owned = Console.new(name: "y", kind: "fake", realm: "personal", principal: agent("muse").first)
    refute agent_owned.valid?
    assert_match(/must be a person/, agent_owned.errors[:principal].join)
  end
end
