require "test_helper"
require_relative "../../support/fake_ynab"

# budget.* (BUDGET.md): how an outside agent reaches the household's budget.
# Muse is a household agent; the house budget is hers to see, Jenner's
# personal one is not, and nothing the handlers do changes that.
class BudgetCapabilitiesTest < ActiveSupport::TestCase
  Ynab = Budgets::Backends::Ynab
  READS = %w[budget.accounts budget.categories budget.transactions budget.transaction.get].freeze
  ACTS = %w[budget.transaction.create budget.transaction.update].freeze

  setup do
    ENV["HOB_TEST_YNAB_TOKEN"] = "ynab-secret"
    native_capabilities!
    @muse, = agent("muse")
    policy!(@muse, "budget.*", "allow")
    budget_backend("house-ynab", realm: "household")
    budget_backend("jenner-ynab", realm: "personal", plan: "plan-private")
    Ynab.transport = (@ynab = FakeYnab.new).to_proc
  end

  teardown do
    Ynab.transport = nil
    ENV.delete("HOB_TEST_YNAB_TOKEN")
  end

  def submit(capability, arguments = {}, agent: @muse, realm: "household")
    as(agent, realm: realm) { Sentinel.submit!(agent: agent, capability: capability, arguments: arguments) }
  end

  def completed(capability, arguments = {}, **rest)
    request = submit(capability, arguments.merge(rest))
    assert_equal "completed", request.status, request.error.to_s
    request.result
  end

  def failed(capability, arguments = {})
    request = submit(capability, arguments)
    assert_equal "failed", request.status
    request.error
  end

  test "sync! registers the six capabilities: reads and acts, at household, with closed schemas that offer the whole contract" do
    caps = Capability.where("name LIKE 'budget.%'").index_by(&:name)
    assert_equal (READS + ACTS).sort, caps.keys.sort, "and nothing that deletes"
    assert_equal READS.sort, caps.values.select { |c| c.kind == "read" }.map(&:name).sort
    caps.each_value do |cap|
      assert cap.native?
      assert_equal "household", cap.realm
      assert_equal false, cap.input_schema["additionalProperties"], cap.name
      assert cap.description.length > 80, "#{cap.name}: agents read these"
    end
    properties = ->(name) { caps[name].input_schema["properties"].keys.sort }
    assert_equal Budgets::ACCOUNT_FILTERS.sort, properties.("budget.accounts")
    assert_equal Budgets::CATEGORY_FILTERS.sort, properties.("budget.categories")
    assert_equal Budgets::TRANSACTION_FILTERS.sort, properties.("budget.transactions")
    assert_equal Budgets::CREATE_ATTRIBUTES.sort, properties.("budget.transaction.create")
    assert_equal (Budgets::UPDATE_ATTRIBUTES + %w[id]).sort, properties.("budget.transaction.update")
    assert_equal Budgets::SPLIT_ATTRIBUTES.sort, caps["budget.transaction.create"].input_schema.dig("properties", "splits", "items", "properties").keys.sort
    assert_equal %w[account amount], caps["budget.transaction.create"].input_schema["required"]
    assert_match(/negative is money out/, caps["budget.transaction.create"].description)
  end

  test "the reads: the budget the agent's clearance can see, with the notice" do
    result = completed("budget.transactions", "since" => "2026-09-01", "category" => "Groceries")
    assert_equal [ 2, 2, -125.67, false ], result.values_at("count", "matched", "total", "truncated")
    assert_equal "house-ynab", result["backend"]
    assert_equal Budgets::NOTICE, result["notice"]
    assert_match(/banks' import feeds.*not instructions/m, result["notice"])
    assert @ynab.calls.all? { |call| call.path.start_with?("/v1/plans/plan-1/") }, "only the household plan was asked"

    assert_equal [ 2345.67, -310.25 ], completed("budget.accounts")["accounts"].map { |a| a["balance"] }
    categories = completed("budget.categories", "month" => "2026-09")
    assert_equal 312.45, categories.dig("month", "ready_to_assign")
    assert_equal Budgets::NOTICE, categories["notice"]
    assert_equal "Blue Bottle", completed("budget.transaction.get", "id" => "house-ynab:t-coffee").dig("transaction", "payee")
  end

  test "a personal budget does not exist for a household agent, whatever it names" do
    assert_match(/NotFound: no budget backend named "jenner-ynab"/, failed("budget.accounts", "backend" => "jenner-ynab"))
    assert_match(/NotFound/, failed("budget.transaction.get", "id" => "jenner-ynab:t-groceries"))
    assert_match(/NotFound/, failed("budget.transaction.update", "id" => "jenner-ynab:t-groceries", "flag" => "red"))
    # An id whose backend is not in sight is just a name nobody has, looked for in the budget that is.
    assert_match(/no account named "jenner-ynab:acc-checking" in house-ynab/,
                 failed("budget.transaction.create", "account" => "jenner-ynab:acc-checking", "amount" => -1))
    assert @ynab.calls.all? { |call| call.path.start_with?("/v1/plans/plan-1/") }, "the private plan was never asked"
    assert_empty @ynab.writes

    skipsy, = agent("skipsy", clearance: "personal")
    policy!(skipsy, "budget.*", "allow")
    request = submit("budget.accounts", { "backend" => "jenner-ynab" }, agent: skipsy, realm: "personal")
    assert_equal "completed", request.status, request.error.to_s
    assert_equal "/v1/plans/plan-private/accounts", @ynab.calls.last.path
  end

  test "the acts: entering and categorizing, and a refusal that says what was wrong" do
    created = completed("budget.transaction.create", "account" => "Visa", "amount" => -4.5, "payee" => "Blue Bottle", "tags" => [ "treat" ])
    assert_equal "house-ynab:t-new", created.dig("transaction", "id")
    assert_equal Budgets::NOTICE, created["notice"]
    assert_equal({ "amount" => -4500, "account_id" => "acc-visa", "payee_id" => nil, "payee_name" => "Blue Bottle", "memo" => "#treat" },
                 @ynab.writes.last.json["transaction"].except("date"))

    completed("budget.transaction.update", "id" => "house-ynab:t-coffee", "category" => "Groceries", "flag" => "red")
    assert_equal({ "category_id" => "cat-groceries", "flag_color" => "red" }, @ynab.writes.last.json["transaction"])

    assert_match(/Invalid: no category named "Grocereis"/, failed("budget.transaction.update", "id" => "house-ynab:t-coffee", "category" => "Grocereis"))
    assert_match(/account is required/, failed("budget.transaction.create", "amount" => -4.5))
    @ynab.error(429, "429", "too_many_requests", "Too many requests")
    assert_match(/Unavailable: YNAB's limit of 200 requests an hour/, failed("budget.accounts"))
  end

  test "policy can keep approval for people: a pattern constraint on `approved`" do
    SentinelPolicy.where(principal: @muse).destroy_all
    policy!(@muse, "budget.transaction.update", "allow", constraints: { "approved" => { "pattern" => "^(false)?$" } })

    request = submit("budget.transaction.update", { "id" => "house-ynab:t-coffee", "approved" => true })
    assert_equal [ "denied", "constraint" ], [ request.status, request.decided_by ]
    assert_equal "completed", submit("budget.transaction.update", { "id" => "house-ynab:t-coffee", "flag" => "red" }).status
    assert_equal 1, @ynab.writes.size
  end

  test "a person's assistant gets the same capabilities as MCP tools, at its own clearance" do
    names = Mcp.tools("household").keys
    (READS + ACTS).each { |name| assert_includes names, name.tr(".", "_") }

    result = as(@principal, realm: "personal") { Mcp.call("budget_accounts", "backend" => "jenner-ynab") }
    assert_equal "jenner-ynab", result["backend"]
    error = assert_raises(Budgets::Invalid) { as(@principal, realm: "personal") { Mcp.call("budget_accounts", {}) } }
    assert_match(/name a backend: one of house-ynab, jenner-ynab/, error.message)
    assert Mcp::ANSWERS.any? { |answer| error.is_a?(answer) }, "which the MCP door reports as the tool's answer, not a fault"
  end
end
