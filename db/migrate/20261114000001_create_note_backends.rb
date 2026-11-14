# Notes (NOTES.md): hob owns an abstract contract over the household's notes
# (folders, search, read, create, append, update); where they actually live
# is a backend, and a backend is a row. The first kind is `quire`, a server
# on the Mac mini wrapping the Notes app. The notes themselves are never
# stored here.
#
# note_backends  one Notes library, as quire serves it to one key: whose it
#                is, the realm of everything in it, and how to reach it
#
# Realm-scoped like text_backends: a backend above the request's clearance
# does not exist as far as that request can tell, and neither does a folder
# or a note in it.
class CreateNoteBackends < ActiveRecord::Migration[8.1]
  def up
    create_table :note_backends, id: :string do |t|
      t.string :name, null: false, index: { unique: true } # "jenner-notes": the prefix of every id
      t.string :kind, null: false                 # quire (an adapter under Notes::Backends)
      t.references :principal, null: false, foreign_key: true # whose notes these are: a person
      t.string :realm, null: false                # of everything in it
      t.jsonb :config, null: false, default: {}   # url, key | key_env, addr, read_only
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE note_backends ENABLE ROW LEVEL SECURITY;
      ALTER TABLE note_backends FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON note_backends
        USING ((SELECT rank FROM realms WHERE slug = note_backends.realm) <= app_clearance_rank());
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON note_backends"
    drop_table :note_backends
  end
end
