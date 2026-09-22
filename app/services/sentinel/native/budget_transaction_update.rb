module Sentinel
  module Native
    # budget.transaction.update: categorize, tag, flag, or correct a
    # transaction. Only what is named changes.
    class BudgetTransactionUpdate < BudgetHandler
      CAPABILITY = {
        "name" => "budget.transaction.update",
        "description" => "Change a transaction in the household budget: only the attributes given are touched. `category` " \
                         "categorizes it (null uncategorizes; a split's categories cannot be changed). `tags` replaces its " \
                         "tags, `add_tags` and `remove_tags` adjust them; tags are kept as #hashtags in the memo, so `memo` " \
                         "replaces them along with the text unless tags are given too. `flag` sets the colored flag, null " \
                         "clears it. `approved: true` approves it on the owner's behalf: do that only when asked to. There is " \
                         "no delete. Returns { transaction: {...}, notice }.",
        "kind" => "act",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => { "id" => ID }.merge(WRITABLE).merge(
            "add_tags" => TAGS.merge("description" => "Tags to add, leaving the rest"),
            "remove_tags" => TAGS.merge("description" => "Tags to take off, leaving the rest")
          ),
          "required" => %w[id],
          "additionalProperties" => false
        }
      }.freeze

      def call
        transaction_result(Budgets.update(require_argument(:id), arguments.except("id")))
      end
    end
  end
end
