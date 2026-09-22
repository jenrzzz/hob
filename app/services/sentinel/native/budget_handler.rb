module Sentinel
  module Native
    # What the budget.* handlers share (BUDGET.md). They are thin: Budgets
    # does the work, at the agent's clearance, so the budgets an agent can
    # reach are the ones RLS shows it and the handlers add no realm logic of
    # their own. Everything handed back carries Budgets::NOTICE, since a
    # payee's name is whatever a bank's feed said it was. What Budgets raises
    # (NotFound, Invalid, Forbidden, Unavailable) fails the request with its
    # message.
    class BudgetHandler < Base
      ID = { "type" => "string", "description" => "A transaction id as budget.transactions returns it: \"<backend>:<id>\"" }.freeze
      BACKEND = { "type" => "string", "description" => "Backend name; needed only when more than one budget is visible" }.freeze
      DATE = "A date, YYYY-MM-DD".freeze
      AMOUNT = "A decimal number in the budget's currency, signed: negative is money out (a 4.50 coffee is -4.5), " \
               "positive is money in".freeze
      TAGS = { "type" => "array", "items" => { "type" => "string" } }.freeze
      TRANSACTION = "{ id, backend, date, amount, payee, account: { id, name }, category: { id, name } or null when " \
                    "uncategorized or split, memo, tags, flag, flag_name, cleared, approved, transfer_account_id, imported, " \
                    "splits: [{ amount, payee, category, memo }] }".freeze

      # The writable attributes budget.transaction.create and .update have in common.
      WRITABLE = {
        "date" => { "type" => "string", "description" => "#{DATE}. Not in the future: YNAB refuses tomorrow" },
        "amount" => { "type" => %w[number string], "description" => AMOUNT },
        "payee" => { "type" => %w[string null], "description" => "The payee's name; one the budget does not know yet is created" },
        "category" => { "type" => %w[string null],
                        "description" => "A category id from budget.categories, or its exact name (\"<group>: <name>\" when two " \
                                         "groups share a name); null leaves it uncategorized" },
        "memo" => { "type" => %w[string null], "description" => "Replaces the memo, its #hashtags included" },
        "tags" => TAGS.merge("description" => "One-word tags, kept as #hashtags at the end of the memo; replaces the whole set"),
        "flag" => { "type" => %w[string null], "enum" => [ *Budgets::FLAGS, nil ], "description" => "The colored flag; null clears it" },
        "cleared" => { "type" => "string", "enum" => Budgets::CLEARED },
        "approved" => { "type" => "boolean",
                        "description" => "Leave it out unless told otherwise: an unapproved transaction waits in the budget " \
                                         "for its owner to approve, which is how a person checks your work" }
      }.freeze

      private

      def noticed(result)
        result.merge("notice" => Budgets::NOTICE)
      end

      def transaction_result(transaction)
        noticed("transaction" => transaction)
      end
    end
  end
end
