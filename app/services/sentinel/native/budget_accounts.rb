module Sentinel
  module Native
    # budget.accounts: the accounts in the budget visible at the agent's
    # clearance, and what is in each.
    class BudgetAccounts < BudgetHandler
      CAPABILITY = {
        "name" => "budget.accounts",
        "description" => "The accounts in the household budget visible at the agent's clearance (YNAB, by way of hob), with " \
                         "their balances. Open accounts by default. Returns { backend, accounts: [{ id, backend, name, kind, " \
                         "on_budget, closed, balance, cleared_balance, uncleared_balance, last_reconciled_at, import_broken, " \
                         "note }], notice }. Balances are decimal amounts in the budget's currency; a credit card's is negative " \
                         "when money is owed. `on_budget: false` is a tracking account (a mortgage, an investment): its balance " \
                         "counts toward net worth and not toward the budget. `import_broken` means the bank link is failing, so " \
                         "the balance may be stale.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "backend" => BACKEND,
            "closed" => { "type" => "boolean", "description" => "true: closed accounts too", "default" => false }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Budgets.accounts(arguments))
      end
    end
  end
end
