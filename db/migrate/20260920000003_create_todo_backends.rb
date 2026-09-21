# Todos (TODOS.md): hob owns an abstract todo contract; where the todos
# actually live is a backend, and a backend is a row. The first kind is
# `omnifocus`, which talks to tally (an HTTP wrapper around OmniFocus on the
# Mac mini). The todos themselves are never stored here.
#
# todo_backends  one place todos live: whose they are, the realm of
#                everything in it, and how to reach it
#
# Realm-scoped like missions and conversations: a backend above the
# request's clearance does not exist as far as that request can tell, and
# neither does anything in it.
class CreateTodoBackends < ActiveRecord::Migration[8.1]
  def up
    create_table :todo_backends, id: :string do |t|
      t.string :name, null: false, index: { unique: true } # "jenner-omnifocus": the prefix of every todo id
      t.string :kind, null: false                 # omnifocus (an adapter under Todos::Backends)
      t.references :principal, null: false, foreign_key: true # whose todos these are: a person
      t.string :realm, null: false                # of everything in it; also the sink realm of any write
      t.jsonb :config, null: false, default: {}   # omnifocus: url, key | key_env, addr
      t.boolean :enabled, null: false, default: true
      t.boolean :primary, null: false, default: false # the owner's default for creates that name no backend
      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE todo_backends ENABLE ROW LEVEL SECURITY;
      ALTER TABLE todo_backends FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON todo_backends
        USING ((SELECT rank FROM realms WHERE slug = todo_backends.realm) <= app_clearance_rank());
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON todo_backends"
    drop_table :todo_backends
  end
end
