require "test_helper"
require_relative "../support/fake_ynab"

# Budgets (BUDGET.md) over the ynab adapter, with YNAB's API faked at the
# transport: what hob sends (paths, queries, bodies, the bearer token), how
# YNAB's milliunits and memos become amounts and tags, what the façade
# filters and totals, and what each of YNAB's errors becomes.
class BudgetsYnabTest < ActiveSupport::TestCase
  Ynab = Budgets::Backends::Ynab

  setup do
    ENV["HOB_TEST_YNAB_TOKEN"] = "ynab-secret"
    @backend = budget_backend("house-ynab", time_zone: "America/Los_Angeles")
    Ynab.transport = (@ynab = FakeYnab.new).to_proc
  end

  teardown do
    Ynab.transport = nil
    ENV.delete("HOB_TEST_YNAB_TOKEN")
  end

  def sent
    @ynab.writes.last.json.fetch("transaction")
  end

  def invalid(message, &block)
    assert_match message, assert_raises(Budgets::Invalid, &block).message
  end

  # --- reading ---

  test "a YNAB transaction becomes a transaction: currency amounts, prefixed ids, tags out of the memo" do
    assert_equal({
      "id" => "house-ynab:t-groceries", "backend" => "house-ynab", "date" => "2026-09-18", "amount" => -45.67,
      "payee" => "Trader Joe's", "account" => { "id" => "house-ynab:acc-checking", "name" => "Checking" },
      "category" => { "id" => "house-ynab:cat-groceries", "name" => "Groceries" }, "memo" => "weekly shop #reimbursable",
      "tags" => [ "reimbursable" ], "flag" => "blue", "flag_name" => "Tax", "cleared" => "cleared", "approved" => true,
      "transfer_account_id" => nil, "imported" => true, "splits" => []
    }, Budgets.find("house-ynab:t-groceries"))

    call = @ynab.calls.last
    assert_equal "GET", call.verb
    assert_equal "https://api.ynab.com/v1/plans/plan-1/transactions/t-groceries", call.url
    assert_equal "Bearer ynab-secret", call.headers["Authorization"]
    assert_nil call.body
  end

  test "a split has no category of its own, its live parts do; an uncategorized transaction has none at all" do
    travel_to Time.utc(2026, 9, 21, 20, 0) do
      by_id = Budgets.transactions["transactions"].index_by { |t| t["id"] }
      costco = by_id.fetch("house-ynab:t-costco")
      assert_nil costco["category"]
      assert_equal [ [ -80.0, "Groceries", "" ], [ -40.0, "Household", "paper towels" ] ],
                   costco["splits"].map { |s| [ s["amount"], s.dig("category", "name"), s["memo"] ] }
      coffee = by_id.fetch("house-ynab:t-coffee")
      assert_nil coffee["category"]
      assert_nil coffee["flag"], "YNAB's empty flag is no flag"
      assert_equal [ false, false, [], "" ], coffee.values_at("approved", "imported", "tags", "memo")
      refute by_id.key?("house-ynab:t-gone"), "deleted transactions are dropped"
    end
  end

  test "transactions: the window goes to YNAB, defaulting to thirty days back from the owner's today" do
    travel_to Time.utc(2026, 9, 22, 3, 0) do # still the 21st in Los Angeles
      result = Budgets.transactions
      assert_equal({ "since_date" => "2026-08-22" }, @ynab.calls.last.query)
      assert_equal "/v1/plans/plan-1/transactions", @ynab.calls.last.path
      assert_equal [ "2026-08-22", nil, "house-ynab" ], result.values_at("since", "until", "backend")
      assert_equal %w[t-coffee t-groceries t-costco], result["transactions"].map { |t| t["id"].split(":").last }, "newest first"
      assert_equal [ 3, -170.17, false ], result.values_at("matched", "total", "truncated")
    end

    Budgets.transactions("since" => "2026-08-01", "until" => "2026-08-31", "unapproved" => true)
    assert_equal({ "since_date" => "2026-08-01", "until_date" => "2026-08-31", "type" => "unapproved" }, @ynab.calls.last.query)
    Budgets.transactions("since" => "2026-08-01", "uncategorized" => true, "unapproved" => true)
    assert_equal "uncategorized", @ynab.calls.last.query["type"], "YNAB takes one type; the façade applies the other"
  end

  test "transactions: filters are applied here, on the normalized shape" do
    ids = ->(filters) { Budgets.transactions({ "since" => "2026-09-01" }.merge(filters))["transactions"].map { |t| t["id"].split(":").last } }

    assert_equal %w[t-coffee], ids.("account" => "visa"), "an account by name, whatever its case"
    assert_equal %w[t-groceries t-costco], ids.("account" => "house-ynab:acc-checking")
    assert_equal %w[t-coffee], ids.("uncategorized" => true)
    assert_equal %w[t-coffee], ids.("unapproved" => "true")
    assert_equal %w[t-groceries], ids.("flag" => "blue")
    assert_equal %w[t-groceries], ids.("tag" => [ "#Reimbursable" ])
    assert_equal [], ids.("tag" => %w[reimbursable tax])
    assert_equal %w[t-costco], ids.("payee" => "cost")
    assert_equal %w[t-costco], ids.("q" => "towels paper"), "a split's memo is searched too"
    assert_equal %w[t-groceries], ids.("until" => "2026-09-19", "q" => "joe's")
    assert_equal %w[t-costco t-groceries t-coffee], ids.("sort" => "amount")
    assert_equal %w[t-costco t-groceries t-coffee], ids.("sort" => "date")
  end

  test "transactions: under a category filter a split counts for its part, and total covers what limit cut" do
    result = Budgets.transactions("since" => "2026-09-01", "category" => "groceries")
    assert_equal %w[house-ynab:t-groceries house-ynab:t-costco], result["transactions"].map { |t| t["id"] }
    assert_equal(-125.67, result["total"], "45.67 and the 80.00 of Costco that was groceries")
    assert_equal(-40.0, Budgets.transactions("since" => "2026-09-01", "category" => "house-ynab:cat-household")["total"])

    cut = Budgets.transactions("since" => "2026-09-01", "limit" => 1)
    assert_equal [ 1, 3, -170.17, true ], [ cut["transactions"].size, *cut.values_at("matched", "total", "truncated") ]
  end

  test "transactions: a bad filter is refused, never ignored" do
    invalid(/unknown filter categroy \(known: backend, since/) { Budgets.transactions("categroy" => "Groceries") }
    invalid(/since must be a date like 2026-09-21/) { Budgets.transactions("since" => "last week") }
    invalid(/since must be a date/) { Budgets.transactions("since" => "2026-02-30") }
    invalid(/until \(2026-08-01\) is before since/) { Budgets.transactions("since" => "2026-09-01", "until" => "2026-08-01") }
    invalid(/flag must be one of red, orange/) { Budgets.transactions("flag" => "pink") }
    invalid(/sort must be one of date, amount/) { Budgets.transactions("sort" => "-payee") }
    invalid(/a tag is one word/) { Budgets.transactions("tag" => [ "two words" ]) }
    invalid(/cannot both/) { Budgets.transactions("category" => "Groceries", "uncategorized" => true) }
    assert_empty @ynab.calls, "nothing was asked of YNAB"
  end

  test "accounts: balances in the currency, open ones unless asked" do
    result = Budgets.accounts
    assert_equal "/v1/plans/plan-1/accounts", @ynab.calls.last.path
    assert_equal %w[Checking Visa], result["accounts"].map { |a| a["name"] }
    assert_equal({
      "id" => "house-ynab:acc-visa", "backend" => "house-ynab", "name" => "Visa", "kind" => "creditCard", "on_budget" => true,
      "closed" => false, "balance" => -310.25, "cleared_balance" => -305.75, "uncleared_balance" => -4.5,
      "last_reconciled_at" => nil, "import_broken" => true, "note" => "pay in full"
    }, result["accounts"].last)
    assert_equal [ "Checking", "Visa", "Old Savings" ], Budgets.accounts("closed" => true)["accounts"].map { |a| a["name"] }
    invalid(/unknown filter open/) { Budgets.accounts("open" => true) }
  end

  test "categories: a month of the budget, with what is left to assign" do
    result = Budgets.categories
    assert_equal "/v1/plans/plan-1/months/current", @ynab.calls.last.path
    assert_equal({ "month" => "2026-09-01", "ready_to_assign" => 312.45, "income" => 5200.0, "assigned" => 1000.0,
                   "activity" => -565.67, "age_of_money" => 41 }, result["month"])
    assert_equal [ "Groceries", "Household", "Vacation", "Fun", "Fun" ], result["categories"].map { |c| c["name"] }
    assert_equal({
      "id" => "house-ynab:cat-vacation", "backend" => "house-ynab", "name" => "Vacation", "group" => "Goals", "assigned" => 250.0,
      "activity" => 0.0, "available" => 1250.0, "goal_target" => 3000.0, "goal_under_funded" => 50.0, "hidden" => false, "note" => ""
    }, result["categories"][2])
    assert_equal(-40.0, result["categories"][1]["available"], "overspent")

    assert_includes Budgets.categories("month" => "2026-08", "hidden" => true)["categories"].map { |c| c["name"] }, "Old Gym"
    assert_equal "/v1/plans/plan-1/months/2026-08-01", @ynab.calls.last.path
    Budgets.categories("month" => "2026-08-17")
    assert_equal "/v1/plans/plan-1/months/2026-08-01", @ynab.calls.last.path
    invalid(/month must be current or a month like 2026-09/) { Budgets.categories("month" => "August") }
  end

  # --- writing ---

  test "create: names are looked up, the amount goes out in milliunits, and it is left for its owner to approve" do
    travel_to Time.utc(2026, 9, 22, 3, 0) do
      created = Budgets.create("account" => "checking", "amount" => -4.5, "payee" => "Blue Bottle", "category" => "Groceries",
                               "memo" => "flat white", "tags" => %w[treat work], "flag" => "green")
      assert_equal "house-ynab:t-new", created["id"]
      assert_equal %w[treat work], created["tags"]
    end

    assert_equal [ "GET /v1/plans/plan-1/categories", "GET /v1/plans/plan-1/accounts", "POST /v1/plans/plan-1/transactions" ],
                 @ynab.calls.map { |c| "#{c.verb} #{c.path}" }
    assert_equal({ "date" => "2026-09-21", "amount" => -4500, "flag_color" => "green", "payee_id" => nil, "payee_name" => "Blue Bottle",
                   "category_id" => "cat-groceries", "account_id" => "acc-checking", "memo" => "flat white #treat #work" }, sent)
    refute sent.key?("approved"), "YNAB's default is unapproved"
    assert_equal "application/json", @ynab.writes.last.headers["Content-Type"]
  end

  test "create: ids need no lookup, and the amount may be a string but never a float's worth of error" do
    Budgets.create("account" => "house-ynab:acc-visa", "category" => "house-ynab:cat-household", "amount" => "1234.56",
                   "date" => "2026-09-01", "approved" => true, "cleared" => "cleared")
    assert_equal 1, @ynab.calls.size
    assert_equal({ "date" => "2026-09-01", "cleared" => "cleared", "approved" => true, "amount" => 1_234_560,
                   "category_id" => "cat-household", "account_id" => "acc-visa" }, sent)

    invalid(/YNAB counts to a thousandth/) { Budgets.create("account" => "house-ynab:acc-visa", "amount" => 0.1 + 0.7) }
    invalid(/YNAB counts to a thousandth/) { Budgets.create("account" => "house-ynab:acc-visa", "amount" => "1.2345") }
    Budgets.create("account" => "house-ynab:acc-visa", "amount" => -19.99)
    assert_equal(-19_990, sent["amount"])
  end

  test "create: a name that is not there, or is there twice, is the caller's to fix" do
    invalid(/no account named "Savings" in house-ynab \(there: Checking; Visa; Old Savings\)/) { Budgets.create("account" => "Savings", "amount" => -1) }
    invalid(%r{category "Fun" is ambiguous \(candidates: Everyday: Fun house-ynab:cat-fun-everyday; Goals: Fun house-ynab:cat-fun-goals\)}) do
      Budgets.create("account" => "Checking", "amount" => -1, "category" => "Fun")
    end
    Budgets.create("account" => "Checking", "amount" => -1, "category" => "goals: fun")
    assert_equal "cat-fun-goals", sent["category_id"], "\"<group>: <name>\" settles it"
    assert_equal 1, @ynab.writes.size
  end

  test "create: what is required, and what is refused before YNAB hears of it" do
    invalid(/account is required/) { Budgets.create("amount" => -1) }
    invalid(/amount is required: negative is money out/) { Budgets.create("account" => "Checking") }
    invalid(/amount must be a number like -12.34/) { Budgets.create("account" => "Checking", "amount" => "$4.50") }
    invalid(/amount must be a number/) { Budgets.create("account" => "Checking", "amount" => true) }
    invalid(/date must be a date/) { Budgets.create("account" => "Checking", "amount" => -1, "date" => "2026-09-21T10:00:00Z") }
    invalid(/unknown attribute import_id/) { Budgets.create("account" => "Checking", "amount" => -1, "import_id" => "x") }
    invalid(/cleared must be one of/) { Budgets.create("account" => "Checking", "amount" => -1, "cleared" => "yes") }
    invalid(/memo is 501 characters; 500 at most/) { Budgets.create("account" => "Checking", "amount" => -1, "memo" => "m" * 501) }
    assert_empty @ynab.calls
  end

  test "create: splits add up to the amount and carry their own categories" do
    Budgets.create("account" => "Checking", "amount" => -120, "payee" => "Costco",
                   "splits" => [ { "amount" => -80, "category" => "Groceries" },
                                 { "amount" => "-40.00", "category" => "house-ynab:cat-household", "memo" => "paper towels" } ])
    assert_nil sent["category_id"]
    assert_equal [ { "amount" => -80_000, "memo" => nil, "category_id" => "cat-groceries" },
                   { "amount" => -40_000, "memo" => "paper towels", "category_id" => "cat-household" } ], sent["subtransactions"]
    assert_equal 1, @ynab.calls.count { |c| c.path.end_with?("/categories") }, "one lookup serves every name"

    invalid(/splits add up to -110.0, not the amount -120.0/) do
      Budgets.create("account" => "Checking", "amount" => -120, "splits" => [ { "amount" => -80 }, { "amount" => -30 } ])
    end
    invalid(/a category or splits, not both/) do
      Budgets.create("account" => "Checking", "amount" => -2, "category" => "Groceries", "splits" => [ { "amount" => -1 }, { "amount" => -1 } ])
    end
    invalid(/at least two parts/) { Budgets.create("account" => "Checking", "amount" => -2, "splits" => [ { "amount" => -2 } ]) }
    invalid(/unknown split attribute flag/) do
      Budgets.create("account" => "Checking", "amount" => -2, "splits" => [ { "amount" => -1, "flag" => "red" }, { "amount" => -1 } ])
    end
  end

  test "update: categorizing by id is one request, and only what is named goes out" do
    Budgets.update("house-ynab:t-coffee", "category" => "house-ynab:cat-groceries")
    assert_equal [ "PUT /v1/plans/plan-1/transactions/t-coffee" ], @ynab.calls.map { |c| "#{c.verb} #{c.path}" }
    assert_equal({ "category_id" => "cat-groceries" }, sent)

    Budgets.update("house-ynab:t-coffee", "category" => nil, "flag" => nil, "payee" => nil, "approved" => true, "amount" => -5)
    assert_equal({ "approved" => true, "amount" => -5000, "flag_color" => nil, "payee_id" => nil, "payee_name" => nil,
                   "category_id" => nil }, sent)
  end

  test "update: tags live in the memo, so they are edited there and the words around them kept" do
    Budgets.update("house-ynab:t-groceries", "add_tags" => %w[Costco reimbursable])
    assert_equal [ "GET", "PUT" ], @ynab.calls.map(&:verb), "the memo is read first"
    assert_equal({ "memo" => "weekly shop #reimbursable #Costco" }, sent)

    Budgets.update("house-ynab:t-groceries", "remove_tags" => [ "REIMBURSABLE" ])
    assert_equal "weekly shop", sent["memo"]
    Budgets.update("house-ynab:t-groceries", "tags" => %w[tax])
    assert_equal "weekly shop #tax", sent["memo"]
    updated = Budgets.update("house-ynab:t-groceries", "tags" => [])
    assert_equal "weekly shop", sent["memo"]
    assert_equal [], updated["tags"]

    before = @ynab.calls.size
    Budgets.update("house-ynab:t-groceries", "memo" => "big shop, apt #4 #old", "add_tags" => [ "party" ])
    assert_equal 1, @ynab.calls.size - before, "a memo given is not read back first"
    assert_equal "big shop, apt #4 #old #party", sent["memo"]
    Budgets.update("house-ynab:t-groceries", "memo" => nil)
    assert_equal "", sent["memo"]

    invalid(/memo and tags come to 5\d\d characters; YNAB keeps 500/) do
      Budgets.update("house-ynab:t-groceries", "memo" => "m" * 495, "add_tags" => [ "overflow" ])
    end
  end

  test "update: what cannot be changed or cleared is refused" do
    invalid(/nothing to update/) { Budgets.update("house-ynab:t-coffee", {}) }
    invalid(/unknown attribute account/) { Budgets.update("house-ynab:t-coffee", "account" => "Visa") }
    invalid(/amount cannot be cleared/) { Budgets.update("house-ynab:t-coffee", "amount" => nil) }
    invalid(/ids look like <backend>:<id>/) { Budgets.update("t-coffee", "flag" => "red") }
    assert_empty @ynab.calls
  end

  # --- which budget ---

  test "a call reaches the one budget in sight, a named one, or the one an id names; never two" do
    budget_backend("jenner-ynab", realm: "personal", plan: "plan-2")
    invalid(/name a backend: one of house-ynab, jenner-ynab/) { Budgets.accounts }
    Budgets.accounts("backend" => "jenner-ynab")
    assert_equal "/v1/plans/plan-2/accounts", @ynab.calls.last.path
    Budgets.transactions("account" => "jenner-ynab:acc-checking")
    assert_equal "/v1/plans/plan-2/transactions", @ynab.calls.last.path
    Budgets.create("account" => "jenner-ynab:acc-checking", "amount" => -1)
    assert_equal "/v1/plans/plan-2/transactions", @ynab.calls.last.path
    invalid(/name different backends: house-ynab, jenner-ynab/) do
      Budgets.create("backend" => "house-ynab", "account" => "jenner-ynab:acc-checking", "amount" => -1)
    end

    clearance!("household")
    assert_equal "house-ynab", Budgets.accounts["backend"], "the personal budget is not in sight, so there is one"
    assert_raises(Budgets::NotFound) { Budgets.accounts("backend" => "jenner-ynab") }
    assert_raises(Budgets::NotFound) { Budgets.find("jenner-ynab:t-groceries") }

    @backend.update!(enabled: false)
    invalid(/no budget backend is visible/) { Budgets.accounts }
  end

  # --- when YNAB says no ---

  test "YNAB's errors become hob's" do
    { [ 401, "401", "unauthorized", "Unauthorized" ] => [ Budgets::Forbidden, /YNAB refused house-ynab's token: Unauthorized/ ],
      [ 403, "403.1", "subscription_lapsed", "Subscription lapsed" ] => [ Budgets::Forbidden, /Subscription lapsed/ ],
      [ 404, "404.2", "resource_not_found", "Resource not found" ] => [ Budgets::NotFound, /Resource not found/ ],
      [ 400, "400", "bad_request", "date must not be in the future" ] => [ Budgets::Invalid, /must not be in the future/ ],
      [ 409, "409", "conflict", "import_id exists" ] => [ Budgets::Invalid, /import_id exists/ ],
      [ 429, "429", "too_many_requests", "Too many requests" ] => [ Budgets::Unavailable, /200 requests an hour/ ],
      [ 503, "503", "service_unavailable", "Down for maintenance" ] => [ Budgets::Unavailable, /HTTP 503: Down for maintenance/ ] }.each do |(status, *error), (klass, message)|
      @ynab.error(status, *error)
      assert_match message, assert_raises(klass) { Budgets.find("house-ynab:t-groceries") }.message
    end

    @ynab.respond(502, "<html>Bad gateway</html>")
    assert_raises(Budgets::Unavailable) { Budgets.accounts }
  end

  test "a 404 on a create is about what the body named, so it is the caller's mistake" do
    @ynab.error(404, "404.2", "resource_not_found", "Resource not found")
    invalid(/Resource not found/) { Budgets.create("account" => "house-ynab:acc-nope", "amount" => -1) }
  end

  test "a network failure, or a token that is not in the environment, is not now" do
    Ynab.transport = ->(*) { raise Errno::ECONNREFUSED }
    assert_match(/YNAB unreachable: ECONNREFUSED/, assert_raises(Budgets::Unavailable) { Budgets.accounts }.message)
    Ynab.transport = ->(*) { raise Net::ReadTimeout }
    assert_raises(Budgets::Unavailable) { Budgets.accounts }

    ENV.delete("HOB_TEST_YNAB_TOKEN")
    Ynab.transport = ->(*) { flunk "no request without a key" }
    assert_match(/house-ynab has no key: HOB_TEST_YNAB_TOKEN is not set/, assert_raises(Budgets::Unavailable) { Budgets.accounts }.message)
  end

  test "check: the token works and sees the plan; plans lists what a token can see before there is a row" do
    assert_equal({ "reachable" => true, "plan" => "plan-1", "plans_visible_to_token" => 2 }, @backend.adapter.check)
    assert_equal "/v1/plans", @ynab.calls.last.path

    pinned = budget_backend("pinned", plan: "11111111-2222-3333-4444-555555555555")
    assert_equal({ "id" => "11111111-2222-3333-4444-555555555555", "name" => "Household", "currency" => "USD",
                   "last_modified_on" => "2026-09-20T18:00:00Z" }, pinned.adapter.check["plan"])
    stray = budget_backend("stray", plan: "00000000-2222-3333-4444-555555555555")
    assert_match(/sees no plan 00000000-.* \(it sees: Household 11111111-.*; Jenner's Business 99999999-/,
                 assert_raises(Budgets::NotFound) { stray.adapter.check }.message)

    assert_equal [ "Household", "Jenner's Business" ], Ynab.plans("some-token").map { |plan| plan["name"] }
    assert_equal "Bearer some-token", @ynab.calls.last.headers["Authorization"]
  end
end
