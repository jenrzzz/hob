require "test_helper"

# http.* (HTTP.md): an outside agent asking hob to make one request to the
# public internet. The rule decides whether this request should be made, a
# reviewer judging it under the rule's guidance; Web decides where it can
# go, and no verdict reaches inside the house.
class HttpCapabilitiesTest < ActiveSupport::TestCase
  UNSUBSCRIBE = "https://lists.example/u/abc123".freeze

  setup do
    native_capabilities!
    @muse, = agent("muse")
    @sent = []
    Web.resolver = ->(host) { host == "inside.example" ? [ "100.90.105.100" ] : [ "93.184.215.14" ] }
    Web.transport = lambda do |verb, uri, _address, body, _headers|
      @sent << [ verb, uri.to_s, body ]
      [ 200, "<p>You have been unsubscribed.</p>", { "Content-Type" => "text/html" } ]
    end
  end

  teardown do
    Web.resolver = nil
    Web.transport = nil
  end

  def submit(capability, arguments, reason: nil)
    as(@muse, realm: "household") { Sentinel.submit!(agent: @muse, capability: capability, arguments: arguments, reason: reason) }
  end

  test "sync! registers http.get and http.post as household acts with closed schemas" do
    caps = Capability.where("name LIKE 'http.%'").index_by(&:name)
    assert_equal %w[http.get http.post], caps.keys.sort
    caps.each_value do |cap|
      assert cap.native?
      assert_equal [ "act", "household", false, false ],
                   [ cap.kind, cap.realm, cap.input_schema["additionalProperties"], cap.requires_person? ], cap.name
      assert_match(/never to an address inside the household/, cap.description)
    end
    assert_equal Web::GET_ARGUMENTS.sort, caps["http.get"].input_schema["properties"].keys.sort
    assert_equal Web::POST_ARGUMENTS.sort, caps["http.post"].input_schema["properties"].keys.sort
    assert_match(/RFC 8058/, caps["http.post"].description)
  end

  test "no rule, no request" do
    request = submit("http.get", { "url" => UNSUBSCRIBE })
    assert_equal [ "denied", "policy" ], [ request.status, request.decided_by ]
    assert_empty @sent
  end

  test "under review: the reviewer judges the URL and the reason, and what it approves goes, with the notice" do
    policy!(@muse, "http.*", "review", guidance: "Muse may follow List-Unsubscribe links from the household's mail. Nothing else.")
    @fake.reply('{"verdict": "approve", "rationale": "a one-click unsubscribe from the list header"}')
    request = submit("http.post", { "url" => UNSUBSCRIBE, "form" => { "List-Unsubscribe" => "One-Click" } },
                     reason: "List-Unsubscribe in house-mail:m1 from Lists Weekly; Tessa asked to leave")

    assert_equal [ "completed", "reviewer" ], [ request.status, request.decided_by ], request.error.to_s
    assert_equal [ [ "POST", UNSUBSCRIBE, "List-Unsubscribe=One-Click" ] ], @sent
    assert_equal "You have been unsubscribed.", request.result["body"]
    assert_equal Web::NOTICE, request.result["notice"]
    brief = @fake.calls.last.messages.last["content"]
    assert_match(/lists\.example/, brief)
    assert_match(/Tessa asked to leave/, brief)
    assert_match(/List-Unsubscribe links/, @fake.calls.last.system)

    @fake.reply('{"verdict": "deny", "rationale": "not an unsubscribe link"}')
    denied = submit("http.get", { "url" => "https://elsewhere.example/?d=secret" }, reason: "curious")
    assert_equal [ "denied", "reviewer" ], [ denied.status, denied.decided_by ]
    assert_equal 1, @sent.size
  end

  test "an approved request still cannot reach inside the house" do
    policy!(@muse, "http.get", "allow")
    request = submit("http.get", { "url" => "http://inside.example/admin" })
    assert_equal "failed", request.status
    assert_match(/\ABlocked: inside\.example resolves to 100\.90\.105\.100/, request.error)
    assert_empty @sent
  end
end
