require "test_helper"

# browse.* (BROWSE.md): how an outside agent browses as the household. The
# goal is judged at browse.open; every step after rides on that session,
# which is the agent's alone; a browser above the agent's clearance is not
# there to be named.
class BrowseCapabilitiesTest < ActiveSupport::TestCase
  Fake = Browse::Backends::Fake
  NAMES = %w[browse.open browse.act browse.snapshot browse.close browse.sessions].freeze

  setup do
    native_capabilities!
    @muse, = agent("muse", clearance: "personal")
    policy!(@muse, "browse.*", "allow")
    @mini = browser("mini", realm: "personal", config: { "domains" => [ "shop.test" ] })
    @site = Fake.site("mini")
    @site.page("https://shop.test/orders", title: "Orders", text: "Order 111 $12.34", links: { "e1" => "https://shop.test/orders/111", "e2" => "https://elsewhere.test/" })
    @site.page("https://shop.test/orders/111", title: "Order 111", text: "Widget $12.34", links: { "e1" => "https://shop.test/orders" })
  end

  teardown { Fake.reset! }

  # Arguments go in braces: a bare string-keyed hash would be taken for keywords.
  def submit(capability, arguments = {}, agent: @muse, realm: "personal")
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments) }
  end

  def completed(capability, arguments = {}, **options)
    request = submit(capability, arguments, **options)
    assert_equal "completed", request.status, request.error.to_s
    request.result
  end

  def failed(capability, arguments = {}, **options)
    request = submit(capability, arguments, **options)
    assert_equal "failed", request.status
    request.error
  end

  def open!(**arguments)
    completed("browse.open", { "goal" => "read September's orders to categorize them in YNAB", "url" => "https://shop.test/orders" }.merge(arguments))
  end

  test "sync! registers the five capabilities: two reads, three acts, at household, with closed schemas" do
    caps = Capability.where(name: NAMES).index_by(&:name)
    assert_equal NAMES.sort, caps.keys.sort
    assert_equal %w[browse.sessions browse.snapshot], caps.values.select { |c| c.kind == "read" }.map(&:name).sort
    assert_equal %w[browse.act browse.close browse.open], caps.values.select { |c| c.kind == "act" }.map(&:name).sort
    caps.each_value do |cap|
      assert cap.native?
      assert_equal "household", cap.realm
      assert_equal false, cap.input_schema["additionalProperties"], cap.name
      assert cap.description.length > 80, "#{cap.name}: agents read these"
    end
    assert_equal %w[goal url], caps["browse.open"].input_schema["required"]
    assert_equal %w[session action], caps["browse.act"].input_schema["required"]
    assert_equal Browse::ACTIONS.keys, caps["browse.act"].input_schema.dig("properties", "action", "enum")
    act_args = caps["browse.act"].input_schema["properties"].keys
    Browse::ACTIONS.values.flatten.uniq.each { |arg| assert_includes act_args, arg, "every action argument is in the schema" }
  end

  test "browse.open: a session for a goal, recorded with the request and the mission; then steps, then close" do
    mission = Mission.create!(assignee: @muse, created_by: @principal, title: "Categorize September", realm: "personal")
    result = as(@muse, realm: "personal") do
      Sentinel.submit!(agent: @muse, capability: "browse.open", on_mission: mission.id,
                       arguments: { "goal" => "read September's orders for YNAB", "url" => "https://shop.test/orders" })
    end
    assert_equal "completed", result.status, result.error.to_s
    session = result.result["session"]
    assert_equal "mini", session["browser"]
    assert_equal "Orders", session["title"]
    assert_match(/link "111" \[ref=e1\]/, result.result["snapshot"])
    assert_equal Browse::NOTICE, result.result["notice"]
    row = BrowseSession.find(session["id"])
    assert_equal @muse, row.principal
    assert_equal result.id, row.sentinel_request_id
    assert_equal mission.id, row.on_mission_id
    assert_equal "read September's orders for YNAB", row.goal

    stepped = completed("browse.act", { "session" => session["id"], "action" => "click", "ref" => "e1" })
    assert_equal "Order 111", stepped["session"]["title"]
    assert_equal 1, stepped["session"]["steps"]
    assert_equal Browse::NOTICE, stepped["notice"]
    read = completed("browse.act", { "session" => session["id"], "action" => "read" })
    assert_equal "Widget $12.34", read["text"]
    snap = completed("browse.snapshot", { "session" => session["id"], "screenshot" => true })
    assert_equal "Order 111", snap["session"]["title"]
    assert snap["screenshot"].present?

    listed = completed("browse.sessions")
    assert_equal [ session["id"] ], listed["sessions"].map { |s| s["id"] }
    assert_equal [ { "name" => "mini", "domains" => [ "shop.test" ] } ], listed["browsers"]

    closed = completed("browse.close", { "session" => session["id"] })
    assert_equal "closed", closed["session"]["status"]
    assert_equal "closed by muse", closed["session"]["close_reason"]
    assert_equal [], completed("browse.sessions")["sessions"]
  end

  test "the goal is required and not a token; a step outside the domains is refused in the browser" do
    assert_match(/goal/, failed("browse.open", { "url" => "https://shop.test/orders" }).to_s)
    session = open!["session"]
    blocked = completed("browse.act", { "session" => session["id"], "action" => "click", "ref" => "e2" })
    assert_equal "Orders", blocked["session"]["title"]
    assert_match(/outside/, blocked["blocked"]["reason"])
    assert_match(/outside this session's domains/, failed("browse.act", { "session" => session["id"], "action" => "navigate", "url" => "https://elsewhere.test/" }))
    assert_match(/not on the page/, failed("browse.act", { "session" => session["id"], "action" => "click", "ref" => "e99" }))
    assert_match(/does not take/, failed("browse.act", { "session" => session["id"], "action" => "reload", "text" => "x" }))
  end

  test "a session is the agent's alone: another agent cannot step, look, or close it" do
    session = open!["session"]
    other, = agent("other", clearance: "personal")
    policy!(other, "browse.*", "allow")
    assert_match(/no session/, failed("browse.act", { "session" => session["id"], "action" => "reload" }, agent: other))
    assert_match(/no session/, failed("browse.snapshot", { "session" => session["id"] }, agent: other))
    assert_match(/no session/, failed("browse.close", { "session" => session["id"] }, agent: other))
    assert_equal [], completed("browse.sessions", {}, agent: other)["sessions"]
    assert_equal "open", BrowseSession.find(session["id"]).status
  end

  test "a household agent cannot see a personal browser, whoever approved the request" do
    tessa_muse, = agent("tessa-muse", clearance: "household")
    policy!(tessa_muse, "browse.*", "allow")
    error = failed("browse.open", { "goal" => "look at the orders for the household ledger", "url" => "https://shop.test/orders" }, agent: tessa_muse, realm: "household")
    assert_match(/no browser is visible/, error)
    assert_equal [], completed("browse.sessions", {}, agent: tessa_muse, realm: "household")["browsers"]

    browser("house", realm: "household", config: {})
    Fake.site("house").page("https://shop.test/orders", title: "Orders (house)")
    result = completed("browse.open", { "goal" => "look at the orders for the household ledger", "url" => "https://shop.test/orders" }, agent: tessa_muse, realm: "household")
    assert_equal "house", result["session"]["browser"]
  end

  test "a browser that is away fails the request with its reason, and no session row is left" do
    Fake.fail!("mini", Browse::Unavailable.new("the mini is asleep"))
    assert_match(/the mini is asleep/, failed("browse.open", { "goal" => "read the orders for the ledger", "url" => "https://shop.test/orders" }))
    assert_equal 0, BrowseSession.count
  end
end
