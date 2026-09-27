require "test_helper"

# Browse (BROWSE.md): sessions for a goal, steps by ref, held to domains,
# over the in-memory Fake. RLS decides which browsers exist for a call;
# the session row decides whose a session is.
class BrowseTest < ActiveSupport::TestCase
  Fake = Browse::Backends::Fake

  setup do
    @mini = browser("mini", config: { "domains" => [ "shop.test" ] })
    @site = Fake.site("mini")
    @site.page("https://shop.test/", title: "Shop", text: "Welcome", links: { "e1" => "https://shop.test/orders", "e2" => "https://elsewhere.test/" }, fields: %w[e3])
    @site.page("https://shop.test/orders", title: "Orders", text: "Order 111 $12.34", links: { "e1" => "https://shop.test/" })
    @site.page("https://www.shop.test/", title: "Shop (www)")
  end

  teardown { Fake.reset! }

  def open(**attrs)
    Browse.open(**{ goal: "read the orders for the ledger", url: "https://shop.test/" }.merge(attrs))
  end

  test "open: a goal, a URL, the only visible browser, and the page comes back with refs" do
    result = open
    session = result["session"]
    assert_match(/\A[0-9A-HJKMNP-TV-Z]{26}\z/, session["id"])
    assert_equal "mini", session["browser"]
    assert_equal "read the orders for the ledger", session["goal"]
    assert_equal "open", session["status"]
    assert_equal 0, session["steps"]
    assert_equal "Shop", session["title"]
    assert_equal [ "shop.test" ], session["domains"]
    assert_match(/link "orders" \[ref=e1\]/, result["snapshot"])
    assert_equal false, result["truncated"]
    assert_nil result["blocked"]
    assert_nil result["screenshot"]

    row = BrowseSession.find(session["id"])
    assert_equal @principal, row.principal
    assert_equal "personal", row.realm
    assert_equal "s1", row.remote_id
    assert_equal [ [ :open, "https://shop.test/", [ "shop.test" ] ] ], @site.calls
  end

  test "open: goal and url are required and checked; the browser must be named when there are two" do
    assert_raises(Browse::Invalid) { open(goal: "") }
    assert_raises(Browse::Invalid) { open(url: "shop.test") }
    assert_raises(Browse::Invalid) { open(url: nil) }
    browser("other", config: {})
    error = assert_raises(Browse::Invalid) { open }
    assert_match(/name the browser: one of mini, other/, error.message)
    assert_equal "other", open(browser: "other")["session"]["browser"]
    assert_raises(Browse::NotFound) { open(browser: "nope") }
    Browser.update_all(enabled: false)
    assert_raises(Browse::NotFound) { open }
  end

  test "open: domains narrow the browser's, never widen them; a screenshot and a ttl ride along" do
    result = open(url: "https://www.shop.test/", domains: [ "www.shop.test" ], ttl: 60, screenshot: true)
    assert_equal [ "www.shop.test" ], result["session"]["domains"]
    assert_match(/outside this key's domains/, assert_raises(Browse::Invalid) { open(domains: [ "www.shop.test" ]) }.message,
                 "the start URL must be inside the narrowed domains too")
    assert_match(/PNG/, Base64.decode64(result["screenshot"]))
    error = assert_raises(Browse::Invalid) { open(domains: [ "elsewhere.test" ]) }
    assert_match(/outside mini's domains/, error.message)
    assert_raises(Browse::Invalid) { open(domains: [ "not a domain" ]) }
    assert_raises(Browse::Invalid) { open(ttl: "soon") }
    assert_equal 60, @site.sessions["s1"]["ttl"]
    open(ttl: 1)
    assert_equal 30, @site.sessions.values.last["ttl"], "ttl is clamped"
  end

  test "act: steps by ref move the tab, count on the row, and hand back the new page" do
    id = open["session"]["id"]
    result = Browse.act(id, "action" => "click", "ref" => "e1")
    assert_equal "Orders", result["session"]["title"]
    assert_equal "https://shop.test/orders", result["session"]["url"]
    assert_equal 1, result["session"]["steps"]
    read = Browse.act(id, "action" => "read")
    assert_equal "Order 111 $12.34", read["text"]
    back = Browse.act(id, "action" => "back")
    assert_equal "Shop", back["session"]["title"]
    typed = Browse.act(id, "action" => "type", "ref" => "e3", "text" => "widgets")
    assert_equal "widgets", @site.sessions["s1"]["typed"]["e3"]
    assert_equal 4, typed["session"]["steps"]
    assert_equal 4, BrowseSession.find(id).steps
    assert_equal "https://shop.test/", BrowseSession.find(id).url
  end

  test "act: the action and its arguments are checked; unknown ones are refused, never ignored" do
    id = open["session"]["id"]
    assert_match(/action is one of/, assert_raises(Browse::Invalid) { Browse.act(id, "action" => "purchase") }.message)
    assert_match(/click does not take text/, assert_raises(Browse::Invalid) { Browse.act(id, "action" => "click", "ref" => "e1", "text" => "x") }.message)
    assert_match(/not on the page/, assert_raises(Browse::Invalid) { Browse.act(id, "action" => "click", "ref" => "e99") }.message)
    assert_match(/like e12/, assert_raises(Browse::Invalid) { Browse.act(id, "action" => "click", "ref" => "button") }.message)
    assert_match(/max_chars must be a number/, assert_raises(Browse::Invalid) { Browse.act(id, "action" => "read", "max_chars" => "lots") }.message)
    assert_equal 0, BrowseSession.find(id).steps, "a refused step is not a step"
    assert_equal 1, @site.calls.count { |call| call.first == :act }, "only the bad ref reached the browser; it is the browser's to judge"
  end

  test "act: a step toward another domain is refused in the browser and reported as blocked" do
    id = open["session"]["id"]
    result = Browse.act(id, "action" => "click", "ref" => "e2")
    assert_equal "Shop", result["session"]["title"], "the tab stayed"
    assert_equal "https://elsewhere.test/", result["blocked"]["url"]
    assert_match(/outside/, result["blocked"]["reason"])
    assert_nil Browse.act(id, "action" => "reload")["blocked"], "cleared by the next step"
  end

  test "act, state, close: a session is its opener's; a person reaches any" do
    muse, = agent("muse", clearance: "personal")
    other, = agent("other", clearance: "personal")
    id = as(muse, realm: "personal") { open["session"]["id"] }
    as(other, realm: "personal") do
      assert_raises(Browse::NotFound) { Browse.act(id, "action" => "reload") }
      assert_raises(Browse::NotFound) { Browse.state(id) }
      assert_raises(Browse::NotFound) { Browse.close(id) }
      assert_equal [], Browse.sessions.to_a
    end
    as(muse, realm: "personal") do
      assert_equal [ id ], Browse.sessions.map(&:id)
      assert_equal "Shop", Browse.state(id)["session"]["title"]
    end
    assert_equal [ id ], Browse.sessions.map(&:id), "the person sees it"
    closed = Browse.close(id)
    assert_equal "closed", closed["status"]
    assert_equal "closed by tester", closed["close_reason"]
    assert_equal "closed by the caller", @site.sessions["s1"]["closed"]
    assert_raises(Browse::Gone) { Browse.act(id, "action" => "reload") }
    assert_equal [], Browse.sessions.to_a
  end

  test "a session the browser has let go is marked on the row and reported gone" do
    id = open["session"]["id"]
    @site.expire!("s1")
    error = assert_raises(Browse::Gone) { Browse.act(id, "action" => "reload") }
    assert_match(/expired/, error.message)
    assert_equal "expired", BrowseSession.find(id).status
    assert_raises(Browse::Gone) { Browse.state(id) }
    assert_equal "expired", Browse.close(id)["status"], "closing what is gone is fine"
  end

  test "a session stops at its step cap" do
    id = open["session"]["id"]
    BrowseSession.find(id).update!(steps: BrowseSession::MAX_STEPS)
    error = assert_raises(Browse::Invalid) { Browse.act(id, "action" => "reload") }
    assert_match(/taken its 300 steps/, error.message)
  end

  test "a browser that cannot be reached says so, and the row is untouched" do
    Fake.fail!("mini", Browse::Unavailable.new("the mini is asleep"))
    assert_raises(Browse::Unavailable) { open }
    assert_equal 0, BrowseSession.count
  end

  test "browsers and sessions are realm-scoped: a household request sees neither" do
    id = open["session"]["id"]
    clearance!("household")
    assert_equal [], Browse.browsers.to_a
    assert_nil BrowseSession.find_by(id: id)
    assert_raises(Browse::NotFound) { Browse.state(id) }
  end
end
