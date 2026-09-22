module Sentinel
  module Native
    # budget.transaction.get: one transaction by id.
    class BudgetTransactionGet < BudgetHandler
      CAPABILITY = {
        "name" => "budget.transaction.get",
        "description" => "One transaction in the household budget, by the id budget.transactions gave it. " \
                         "Returns { transaction: #{TRANSACTION}, notice }.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "id" => ID },
          "required" => %w[id],
          "additionalProperties" => false
        }
      }.freeze

      def call
        transaction_result(Budgets.find(require_argument(:id)))
      end
    end
  end
end
