module Sentinel
  module Native
    # budget.transaction.create: enter a transaction in a budget the agent
    # can see. It arrives unapproved unless the agent says otherwise, so it
    # waits in YNAB for its owner's nod like anything a bank import brings in.
    class BudgetTransactionCreate < BudgetHandler
      CAPABILITY = {
        "name" => "budget.transaction.create",
        "description" => "Enter a transaction in the household budget: money that was actually spent or received, not a plan " \
                         "to. `account` and `amount` are required, and the amount is signed: negative is money out, so a 4.50 " \
                         "coffee is -4.5. `date` defaults to today. Give a `category`, or `splits` when one payment covers " \
                         "several (the parts must add up to the amount), or neither to leave it uncategorized. It arrives " \
                         "unapproved, waiting for the budget's owner, unless `approved` is true. Check budget.transactions " \
                         "first when the bank may already have imported it: entering it twice is the mistake to avoid. " \
                         "Returns { transaction: {...}, notice }; keep the transaction's id to change it later.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => WRITABLE.merge(
            "backend" => BACKEND,
            "account" => { "type" => "string", "description" => "An account id from budget.accounts, or its exact name" },
            "splits" => {
              "type" => "array", "minItems" => 2, "description" => "Instead of category: the parts of one payment, adding up to amount",
              "items" => { "type" => "object",
                           "properties" => WRITABLE.slice("amount", "category", "payee").merge("memo" => { "type" => "string" }),
                           "required" => %w[amount], "additionalProperties" => false }
            }
          ),
          "required" => %w[account amount],
          "additionalProperties" => false
        }
      }.freeze

      def call
        require_argument(:account)
        transaction_result(Budgets.create(arguments))
      end
    end
  end
end
