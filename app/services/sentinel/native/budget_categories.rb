module Sentinel
  module Native
    # budget.categories: a month of the budget, category by category.
    class BudgetCategories < BudgetHandler
      CAPABILITY = {
        "name" => "budget.categories",
        "description" => "A month of the household budget: what was assigned to each category, what was spent from it, and " \
                         "what is left. Returns { backend, month: { month, ready_to_assign, income, assigned, activity, " \
                         "age_of_money }, categories: [{ id, backend, name, group, assigned, activity, available, goal_target, " \
                         "goal_under_funded, hidden, note }], notice }. `available` is the category's balance: negative is " \
                         "overspent. `activity` is negative for spending. `ready_to_assign` is money not yet given a job. Use " \
                         "a category's id or name to categorize a transaction.",
        "kind" => "read",
        "realm" => "household",
        "input_schema" => {
          "type" => "object",
          "properties" => {
            "backend" => BACKEND,
            "month" => { "type" => "string", "description" => "current (the default), or a month like 2026-09",
                         "pattern" => "^(current|\\d{4}-\\d{2}(-\\d{2})?)$" },
            "hidden" => { "type" => "boolean", "description" => "true: hidden categories too", "default" => false }
          },
          "additionalProperties" => false
        }
      }.freeze

      def call
        noticed(Budgets.categories(arguments))
      end
    end
  end
end
