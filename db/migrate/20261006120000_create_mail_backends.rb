# Mail (MAIL.md): hob owns an abstract mail contract (mailboxes, search,
# poll, move, send, reply); where the mail actually lives is a backend, and
# a backend is a row. The first kind is `fastmail` (JMAP), with `jmap` for
# any other JMAP server. The messages themselves are never stored here.
#
# mail_backends  one mail account: whose it is, the realm of everything in
#                it, and how to reach it
#
# Realm-scoped like calendar_backends: a backend above the request's
# clearance does not exist as far as that request can tell, and neither
# does a message in it.
class CreateMailBackends < ActiveRecord::Migration[8.1]
  def up
    create_table :mail_backends, id: :string do |t|
      t.string :name, null: false, index: { unique: true } # "jenner-fastmail": the prefix of every id
      t.string :kind, null: false                 # fastmail | jmap (an adapter under Email::Backends)
      t.references :principal, null: false, foreign_key: true # whose mail this is: a person
      t.string :realm, null: false                # of everything in it
      t.jsonb :config, null: false, default: {}   # key | key_env, url, mailboxes, read_only
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE mail_backends ENABLE ROW LEVEL SECURITY;
      ALTER TABLE mail_backends FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON mail_backends
        USING ((SELECT rank FROM realms WHERE slug = mail_backends.realm) <= app_clearance_rank());
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON mail_backends"
    drop_table :mail_backends
  end
end
