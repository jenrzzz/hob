# The household's consoles (KVM.md): a screen, a keyboard, and a mouse on
# a real computer, lent to an agent a session at a time.
#
# consoles          one KVM (a JetKVM), the machine it is plugged into,
#                   whose that machine is, the realm of everything on its
#                   screen, and how to reach it (the bridge)
# console_sessions  a session an agent opened, for a stated goal: the record
#                   of it. The screen is never stored.
#
# Both realm-scoped like browsers: a console above the request's clearance
# does not exist as far as that request can tell, nor does a session on it.
class CreateConsoles < ActiveRecord::Migration[8.1]
  def up
    create_table :consoles, id: :string do |t|
      t.string :name, null: false, index: { unique: true } # "jenner-mac"
      t.string :kind, null: false                 # jetkvm (an adapter under Consoles::Backends)
      t.references :principal, null: false, foreign_key: true # the machine's owner: a person
      t.string :realm, null: false                # of everything on its screen
      t.jsonb :config, null: false, default: {}   # jetkvm: url (the bridge), key | key_env, addr
      t.string :machine                           # free text: "Jenner's MacBook"
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    create_table :console_sessions, id: :string do |t|
      t.references :console, null: false, foreign_key: true, type: :string
      t.references :principal, null: false, foreign_key: true # who opened it: the agent, or a person
      t.string :realm, null: false                # the console's
      t.text :goal, null: false                   # what the session is for
      t.string :remote_id, null: false            # the bridge's own session id
      t.string :status, null: false, default: "open" # open | closed | expired | lost
      t.integer :steps, null: false, default: 0
      t.integer :ttl, null: false                 # seconds without a step before it ends
      t.datetime :expires_at, null: false         # when it ends without another step
      t.string :close_reason
      t.string :sentinel_request_id               # the request that opened it, when an agent did
      t.string :on_mission_id                     # the mission the agent was on
      t.datetime :last_step_at
      t.datetime :closed_at
      t.timestamps
    end
    add_index :console_sessions, [ :principal_id, :status ]
    add_index :console_sessions, [ :status, :expires_at ]

    execute <<~SQL
      ALTER TABLE consoles ENABLE ROW LEVEL SECURITY;
      ALTER TABLE consoles FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON consoles
        USING ((SELECT rank FROM realms WHERE slug = consoles.realm) <= app_clearance_rank());
      ALTER TABLE console_sessions ENABLE ROW LEVEL SECURITY;
      ALTER TABLE console_sessions FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON console_sessions
        USING ((SELECT rank FROM realms WHERE slug = console_sessions.realm) <= app_clearance_rank());
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON console_sessions"
    execute "DROP POLICY IF EXISTS realm_visibility ON consoles"
    drop_table :console_sessions
    drop_table :consoles
  end
end
