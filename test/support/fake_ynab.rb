# YNAB's API as far as hob uses it, answering from canned data: what
# Budgets::Backends::Ynab.transport is pointed at in tests. It keeps every
# call it was sent; a response pushed with `respond` is served before the
# canned ones.
class FakeYnab
  Call = Struct.new(:verb, :url, :body, :headers) do
    def uri = URI(url)
    def path = uri.path
    def query = URI.decode_www_form(uri.query.to_s).to_h
    def json = body && JSON.parse(body)
  end

  GROCERIES = {
    "id" => "t-groceries", "date" => "2026-09-18", "amount" => -45_670, "memo" => "weekly shop #reimbursable", "cleared" => "cleared",
    "approved" => true, "flag_color" => "blue", "flag_name" => "Tax", "account_id" => "acc-checking", "payee_id" => "pay-tj",
    "category_id" => "cat-groceries", "transfer_account_id" => nil, "transfer_transaction_id" => nil, "matched_transaction_id" => nil,
    "import_id" => "YNAB:-45670:2026-09-18:1", "deleted" => false, "account_name" => "Checking", "payee_name" => "Trader Joe's",
    "category_name" => "Groceries", "subtransactions" => []
  }.freeze

  COSTCO = GROCERIES.merge(
    "id" => "t-costco", "date" => "2026-09-12", "amount" => -120_000, "memo" => nil, "flag_color" => nil, "flag_name" => nil,
    "payee_id" => "pay-costco", "payee_name" => "Costco", "category_id" => "cat-split", "category_name" => "Split", "import_id" => nil,
    "subtransactions" => [
      { "id" => "s-1", "transaction_id" => "t-costco", "amount" => -80_000, "memo" => nil, "payee_id" => nil, "payee_name" => nil,
        "category_id" => "cat-groceries", "category_name" => "Groceries", "deleted" => false },
      { "id" => "s-2", "transaction_id" => "t-costco", "amount" => -40_000, "memo" => "paper towels", "payee_id" => nil,
        "payee_name" => nil, "category_id" => "cat-household", "category_name" => "Household", "deleted" => false },
      { "id" => "s-3", "transaction_id" => "t-costco", "amount" => -1_000, "memo" => "gone", "payee_id" => nil, "payee_name" => nil,
        "category_id" => "cat-household", "category_name" => "Household", "deleted" => true }
    ]
  ).freeze

  COFFEE = GROCERIES.merge(
    "id" => "t-coffee", "date" => "2026-09-20", "amount" => -4_500, "memo" => "", "cleared" => "uncleared", "approved" => false,
    "flag_color" => "", "flag_name" => nil, "account_id" => "acc-visa", "account_name" => "Visa", "payee_id" => "pay-bb",
    "payee_name" => "Blue Bottle", "category_id" => nil, "category_name" => "Uncategorized", "import_id" => nil
  ).freeze

  ACCOUNTS = [
    { "id" => "acc-checking", "name" => "Checking", "type" => "checking", "on_budget" => true, "closed" => false, "note" => nil,
      "balance" => 2_345_670, "cleared_balance" => 2_400_000, "uncleared_balance" => -54_330, "transfer_payee_id" => "pay-x1",
      "direct_import_linked" => true, "direct_import_in_error" => false, "last_reconciled_at" => "2026-09-01T12:00:00Z", "deleted" => false },
    { "id" => "acc-visa", "name" => "Visa", "type" => "creditCard", "on_budget" => true, "closed" => false, "note" => "pay in full",
      "balance" => -310_250, "cleared_balance" => -305_750, "uncleared_balance" => -4_500, "transfer_payee_id" => "pay-x2",
      "direct_import_linked" => true, "direct_import_in_error" => true, "last_reconciled_at" => nil, "deleted" => false },
    { "id" => "acc-old", "name" => "Old Savings", "type" => "savings", "on_budget" => true, "closed" => true, "note" => nil,
      "balance" => 0, "cleared_balance" => 0, "uncleared_balance" => 0, "transfer_payee_id" => "pay-x3", "deleted" => false },
    { "id" => "acc-gone", "name" => "Deleted", "type" => "cash", "on_budget" => true, "closed" => false, "balance" => 0,
      "cleared_balance" => 0, "uncleared_balance" => 0, "transfer_payee_id" => "pay-x4", "deleted" => true }
  ].freeze

  category = lambda do |id, name, group, budgeted, activity, balance, **extra|
    { "id" => id, "category_group_id" => "grp-#{group.downcase}", "category_group_name" => group, "name" => name, "hidden" => false,
      "internal" => false, "note" => nil, "budgeted" => budgeted, "activity" => activity, "balance" => balance, "goal_target" => nil,
      "goal_under_funded" => nil, "deleted" => false }.merge(extra.stringify_keys)
  end
  CATEGORIES = [
    category.("cat-groceries", "Groceries", "Everyday", 600_000, -425_670, 174_330),
    category.("cat-household", "Household", "Everyday", 100_000, -140_000, -40_000),
    category.("cat-vacation", "Vacation", "Goals", 250_000, 0, 1_250_000, goal_target: 3_000_000, goal_under_funded: 50_000),
    category.("cat-fun-everyday", "Fun", "Everyday", 50_000, 0, 50_000),
    category.("cat-fun-goals", "Fun", "Goals", 0, 0, 0),
    category.("cat-hidden", "Old Gym", "Everyday", 0, 0, 0, hidden: true),
    category.("cat-gone", "Deleted", "Everyday", 0, 0, 0, deleted: true)
  ].freeze

  MONTH = { "month" => "2026-09-01", "note" => nil, "income" => 5_200_000, "budgeted" => 1_000_000, "activity" => -565_670,
            "to_be_budgeted" => 312_450, "age_of_money" => 41, "deleted" => false, "categories" => CATEGORIES }.freeze

  PLANS = [
    { "id" => "11111111-2222-3333-4444-555555555555", "name" => "Household", "last_modified_on" => "2026-09-20T18:00:00Z",
      "currency_format" => { "iso_code" => "USD" } },
    { "id" => "99999999-2222-3333-4444-555555555555", "name" => "Jenner's Business", "last_modified_on" => "2026-08-02T09:00:00Z",
      "currency_format" => nil }
  ].freeze

  attr_reader :calls

  def initialize
    @calls = []
    @responses = []
  end

  def respond(status, data)
    @responses << [ status, data.is_a?(String) ? data : data.to_json ]
  end

  def error(status, id, name, detail)
    respond(status, "error" => { "id" => id, "name" => name, "detail" => detail })
  end

  def to_proc
    method(:call).to_proc
  end

  def call(verb, url, body, headers)
    @calls << Call.new(verb, url, body, headers)
    @responses.shift || canned(verb, URI(url).path, body)
  end

  def writes
    calls.reject { |call| call.verb == "GET" }
  end

  private

  def canned(verb, path, body)
    case [ verb, path ]
    in [ "GET", "/v1/plans" ] then data(200, "plans" => PLANS)
    in [ "GET", %r{/accounts\z} ] then data(200, "accounts" => ACCOUNTS)
    in [ "GET", %r{/categories\z} ] then data(200, "category_groups" => CATEGORIES.group_by { |c| c["category_group_name"] }
                                                                                    .map { |group, all| { "name" => group, "categories" => all } })
    in [ "GET", %r{/months/} ] then data(200, "month" => MONTH)
    in [ "GET", %r{/transactions\z} ] then data(200, "transactions" => [ GROCERIES, COSTCO, COFFEE, GROCERIES.merge("id" => "t-gone", "deleted" => true) ])
    in [ "GET", %r{/transactions/t-coffee\z} ] then data(200, "transaction" => COFFEE)
    in [ "GET", %r{/transactions/} ] then data(200, "transaction" => GROCERIES)
    # A write answers with what it was sent, laid over a transaction: enough to see it took.
    in [ "POST" | "PUT", _ ] then data(verb == "POST" ? 201 : 200, "transaction" => written(path, JSON.parse(body).fetch("transaction")))
    else [ 404, { "error" => { "id" => "404.2", "name" => "resource_not_found", "detail" => "Resource not found" } }.to_json ]
    end
  end

  def written(path, sent)
    base = path.end_with?("/t-coffee") ? COFFEE : GROCERIES.merge("id" => "t-new", "memo" => nil, "flag_color" => nil, "import_id" => nil)
    base.merge(sent.except("subtransactions", "payee_name")).merge("payee_name" => sent.fetch("payee_name", base["payee_name"]))
  end

  def data(status, payload)
    [ status, { "data" => payload.merge("server_knowledge" => 100) }.to_json ]
  end
end
