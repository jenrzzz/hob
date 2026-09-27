require "test_helper"

# Browse::Backends::Gofer: what hob sends gofer and what it makes of the
# answers (gofer's API.md), with the wire stubbed.
class BrowseGoferTest < ActiveSupport::TestCase
  Gofer = Browse::Backends::Gofer

  STATE = { "id" => "4kQS4Qa5RyB1", "key" => "hob", "url" => "https://www.amazon.com/", "title" => "Amazon.com",
            "domains" => [ "amazon.com" ], "created_at" => "2026-09-27T07:22:10Z", "expires_at" => "2026-09-27T07:37:10Z",
            "steps" => 0, "snapshot" => "- link \"Returns & Orders\" [ref=e12]", "truncated" => false, "blocked" => nil }.freeze

  setup do
    ENV["HOB_TEST_GOFER_KEY"] = "gofer-secret"
    @row = browser("mini", kind: "gofer", config: { "url" => "http://mini.test:8378/", "key_env" => "HOB_TEST_GOFER_KEY", "addr" => "100.64.0.7" })
    @calls = []
    @responses = []
    Gofer.transport = lambda do |verb, url, body, headers|
      @calls << [ verb, url, body && JSON.parse(body), headers ]
      @responses.shift || [ 200, STATE.to_json ]
    end
  end

  teardown do
    Gofer.transport = nil
    ENV.delete("HOB_TEST_GOFER_KEY")
  end

  def adapter
    @row.adapter
  end

  test "open posts the session body with the key; the trailing slash on the url is dropped" do
    state = adapter.open(url: "https://www.amazon.com/", domains: [ "amazon.com" ], ttl: 600, screenshot: false, max_chars: 40_000)
    assert_equal STATE, state
    verb, url, body, headers = @calls.last
    assert_equal "POST", verb
    assert_equal "http://mini.test:8378/v1/sessions", url
    assert_equal({ "url" => "https://www.amazon.com/", "screenshot" => false, "max_chars" => 40_000, "domains" => [ "amazon.com" ], "ttl" => 600 }, body)
    assert_equal "Bearer gofer-secret", headers["Authorization"]
    assert_equal "application/json", headers["Content-Type"]
  end

  test "open without domains or ttl sends neither" do
    adapter.open(url: "https://www.amazon.com/", domains: [], ttl: nil, screenshot: true, max_chars: 1000)
    assert_equal({ "url" => "https://www.amazon.com/", "screenshot" => true, "max_chars" => 1000 }, @calls.last[2])
  end

  test "state, act, close, check hit their paths" do
    adapter.state("4kQS4Qa5RyB1", screenshot: true, max_chars: 2000)
    assert_equal [ "GET", "http://mini.test:8378/v1/sessions/4kQS4Qa5RyB1?screenshot=1&max_chars=2000", nil ], @calls.last.first(3)

    adapter.act("4kQS4Qa5RyB1", { "action" => "click", "ref" => "e12", "max_chars" => 40_000 })
    assert_equal [ "POST", "http://mini.test:8378/v1/sessions/4kQS4Qa5RyB1/actions", { "action" => "click", "ref" => "e12", "max_chars" => 40_000 } ], @calls.last.first(3)

    @responses << [ 200, { "id" => "4kQS4Qa5RyB1", "closed" => true, "steps" => 3 }.to_json ]
    assert_equal true, adapter.close("4kQS4Qa5RyB1")
    assert_equal [ "DELETE", "http://mini.test:8378/v1/sessions/4kQS4Qa5RyB1" ], @calls.last.first(2)

    @responses << [ 200, { "gofer" => "0.1.0", "browser" => { "running" => true, "version" => "141.0" }, "sessions" => 1,
                           "limits" => { "sessions" => 4 }, "key" => { "name" => "hob", "domains" => [ "amazon.com" ] } }.to_json ]
    check = adapter.check
    assert_equal true, check["reachable"]
    assert_equal "0.1.0", check["gofer"]
    assert_equal [ "amazon.com" ], check.dig("gofer_key", "domains")
  end

  test "gofer's statuses become Browse's errors" do
    { 404 => Browse::NotFound, 410 => Browse::Gone, 422 => Browse::Invalid, 400 => Browse::Invalid, 401 => Browse::Forbidden,
      403 => Browse::Forbidden, 429 => Browse::Unavailable, 502 => Browse::Unavailable, 500 => Browse::Unavailable }.each do |status, klass|
      @responses << [ status, { "error" => "because #{status}" }.to_json ]
      error = assert_raises(klass, status.to_s) { adapter.state("x", screenshot: false, max_chars: nil) }
      assert_match(/because #{status}/, error.message)
    end
    @responses << [ 502, "<html>gateway</html>" ]
    assert_match(/gateway/, assert_raises(Browse::Unavailable) { adapter.state("x", screenshot: false, max_chars: nil) }.message)
  end

  test "no key, or no way to the mini, is unavailable, not a crash" do
    ENV.delete("HOB_TEST_GOFER_KEY")
    error = assert_raises(Browse::Unavailable) { adapter.check }
    assert_match(/HOB_TEST_GOFER_KEY is not set/, error.message)
    assert_empty @calls

    ENV["HOB_TEST_GOFER_KEY"] = "back"
    Gofer.transport = ->(*) { raise Errno::ECONNREFUSED, "connect(2)" }
    error = assert_raises(Browse::Unavailable) { adapter.check }
    assert_match(/gofer unreachable at mini.test/, error.message)
  end
end
