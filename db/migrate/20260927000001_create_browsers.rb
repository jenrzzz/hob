# The household's browsers (BROWSE.md): where an agent can browse as the
# household, and the sessions it has open there.
#
# browsers         one real browser somewhere in the house (gofer on the Mac
#                  mini): whose it is, the realm of everything done in it, and
#                  how to reach it
# browse_sessions  a tab an agent opened, for a stated goal: the record of the
#                  visit, and what binds each step to the goal that was judged
#
# Both realm-scoped like todo_backends: a browser above the request's
# clearance does not exist as far as that request can tell, nor does a
# session in it.
class CreateBrowsers < ActiveRecord::Migration[8.1]
  def up
    create_table :browsers, id: :string do |t|
      t.string :name, null: false, index: { unique: true } # "mini-chrome"
      t.string :kind, null: false                 # gofer (an adapter under Browse::Backends)
      t.references :principal, null: false, foreign_key: true # whose browser this is: a person; its profile is their logins
      t.string :realm, null: false                # of everything seen or done in it
      t.jsonb :config, null: false, default: {}   # gofer: url, key | key_env, addr, domains
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    create_table :browse_sessions, id: :string do |t|
      t.references :browser, null: false, foreign_key: true, type: :string
      t.references :principal, null: false, foreign_key: true # who opened it: the agent, or a person
      t.string :realm, null: false                # the browser's
      t.text :goal, null: false                   # what the visit is for, as judged when it opened
      t.jsonb :domains, null: false, default: [] # where it may go
      t.string :remote_id, null: false            # the backend's own session id
      t.string :status, null: false, default: "open" # open | closed | expired | lost
      t.integer :steps, null: false, default: 0
      t.string :url                               # where it was last seen
      t.string :title
      t.string :close_reason
      t.string :sentinel_request_id               # the request that opened it, when an agent did
      t.string :on_mission_id                     # the mission the agent was on
      t.datetime :last_step_at
      t.datetime :closed_at
      t.timestamps
    end
    add_index :browse_sessions, [ :principal_id, :status ]

    execute <<~SQL
      ALTER TABLE browsers ENABLE ROW LEVEL SECURITY;
      ALTER TABLE browsers FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON browsers
        USING ((SELECT rank FROM realms WHERE slug = browsers.realm) <= app_clearance_rank());
      ALTER TABLE browse_sessions ENABLE ROW LEVEL SECURITY;
      ALTER TABLE browse_sessions FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON browse_sessions
        USING ((SELECT rank FROM realms WHERE slug = browse_sessions.realm) <= app_clearance_rank());
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON browse_sessions"
    execute "DROP POLICY IF EXISTS realm_visibility ON browsers"
    drop_table :browse_sessions
    drop_table :browsers
  end
end
