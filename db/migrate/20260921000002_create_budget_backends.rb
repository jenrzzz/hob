# Budgets (BUDGET.md): hob owns an abstract budget contract (accounts,
# categories, transactions); where the books are actually kept is a backend,
# and a backend is a row. The first kind is `ynab`, which talks to YNAB's
# API. The money itself is never stored here.
#
# budget_backends  one place a budget is kept: whose it is, the realm of
#                  everything in it, and how to reach it
#
# Realm-scoped like todo_backends: a backend above the request's clearance
# does not exist as far as that request can tell, and neither does a cent
# in it.
class CreateBudgetBackends < ActiveRecord::Migration[8.1]
  def up
    create_table :budget_backends, id: :string do |t|
      t.string :name, null: false, index: { unique: true } # "house-ynab": the prefix of every id
      t.string :kind, null: false                 # ynab (an adapter under Budgets::Backends)
      t.references :principal, null: false, foreign_key: true # whose budget this is: a person
      t.string :realm, null: false                # of everything in it; also the sink realm of any write
      t.jsonb :config, null: false, default: {}   # ynab: plan, key | key_env, time_zone
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE budget_backends ENABLE ROW LEVEL SECURITY;
      ALTER TABLE budget_backends FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON budget_backends
        USING ((SELECT rank FROM realms WHERE slug = budget_backends.realm) <= app_clearance_rank());
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON budget_backends"
    drop_table :budget_backends
  end
end
