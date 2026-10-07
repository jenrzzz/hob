# Texts (TEXTS.md): hob owns an abstract contract over the household's text
# messages (chats, messages, poll, send); where they actually live is a
# backend, and a backend is a row. The first kind is `herald`, a server on
# the Mac mini wrapping the Messages app. The messages themselves are never
# stored here.
#
# text_backends  one Messages account, as herald serves it: whose it is, the
#                realm of everything in it, and how to reach it
#
# Realm-scoped like mail_backends: a backend above the request's clearance
# does not exist as far as that request can tell, and neither does a chat
# or a message in it.
class CreateTextBackends < ActiveRecord::Migration[8.1]
  def up
    create_table :text_backends, id: :string do |t|
      t.string :name, null: false, index: { unique: true } # "jenner-messages": the prefix of every id
      t.string :kind, null: false                 # herald (an adapter under Texts::Backends)
      t.references :principal, null: false, foreign_key: true # whose messages these are: a person
      t.string :realm, null: false                # of everything in it
      t.jsonb :config, null: false, default: {}   # url, key | key_env, addr, read_only
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE text_backends ENABLE ROW LEVEL SECURITY;
      ALTER TABLE text_backends FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON text_backends
        USING ((SELECT rank FROM realms WHERE slug = text_backends.realm) <= app_clearance_rank());
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON text_backends"
    drop_table :text_backends
  end
end
