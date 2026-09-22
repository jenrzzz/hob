module Sentinel
  module Native
    # budget.transactions: the transactions in a period, filtered, with
    # their sum. Which budget that reaches is RLS's answer; the handler adds
    # nothing.
    class BudgetTransactions < BudgetHandler
      CAPABILITY = {
        "name" => "budget.transactions",
        "description" => "Transactions in the household budget between `since` and `until`, newest first; the last " \
                         "#{Budgets::DEFAULT_WINDOW} days when no `since` is given. Filter by account, category, payee, flag, " \
                         "tags, text, or what still needs attention (`uncategorized`, `unapproved`). Returns { backend, since, " \
                         "until, transactions: [#{TRANSACTION}], count, matched, total, truncated, notice }. `total` sums every " \
                         "transaction that matched, not only the `limit` returned (`truncated` says when those differ), so " \
                         "\"how much went to groceries in August\" is one call; under a `category` filter a split counts for " \
                         "its part in that category. Amounts are signed: negative is money out.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "backend" => BACKEND,
            "since" => { "type" => "string", "description" => "On or after. #{DATE}; default #{Budgets::DEFAULT_WINDOW} days ago" },
            "until" => { "type" => "string", "description" => "On or before. #{DATE}" },
            "account" => { "type" => "string", "description" => "An account id from budget.accounts, or its exact name" },
            "category" => { "type" => "string", "description" => "A category id from budget.categories, or its exact name" },
            "payee" => { "type" => "string", "description" => "Text the payee's name contains" },
            "uncategorized" => { "type" => "boolean", "description" => "true: only transactions with no category yet" },
            "unapproved" => { "type" => "boolean", "description" => "true: only transactions the owner has not approved yet" },
            "flag" => { "type" => "string", "enum" => Budgets::FLAGS },
            "tag" => TAGS.merge("description" => "Tags (without the #); a transaction must carry every one"),
            "q" => { "type" => "string", "description" => "Words that must all appear in the payee or memo" },
            "sort" => { "type" => "string", "description" => "date or amount; prefix - to reverse. Default -date",
                        "pattern" => "^-?(#{Budgets::SORTS.join('|')})$" },
            "limit" => { "type" => "integer", "minimum" => 1, "maximum" => Budgets::MAX_LIMIT, "default" => Budgets::DEFAULT_LIMIT }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        result = Budgets.transactions(arguments)
        noticed(result.merge("count" => result["transactions"].size))
      end
    end
  end
end
