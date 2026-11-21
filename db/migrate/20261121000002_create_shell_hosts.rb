# Machines an agent may run commands on (SHELL.md): a login over ssh, lent
# a command at a time through shell.*.
#
# shell_hosts   one login on one machine: whose it is, the realm of what is
#               on it, how to reach it, and, optionally, the one agent it is
#               kept for
#
# Realm-scoped like consoles: a host above the request's clearance does not
# exist as far as that request can tell. There is no session table: every
# command is its own connection, and its sentinel request is the record.
class CreateShellHosts < ActiveRecord::Migration[8.1]
  def up
    create_table :shell_hosts, id: :string do |t|
      t.string :name, null: false, index: { unique: true } # "meluzina-box"
      t.string :kind, null: false                 # ssh (an adapter under Shells::Backends)
      t.references :principal, null: false, foreign_key: true # who answers for the machine: a person
      t.references :agent, null: true, foreign_key: { to_table: :principals } # the one agent it is kept for
      t.string :realm, null: false                # of everything on the machine
      t.jsonb :config, null: false, default: {}   # ssh: host, port, user, key | key_env, host_key
      t.string :about                             # free text an agent reads: what the machine is, what it serves
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE shell_hosts ENABLE ROW LEVEL SECURITY;
      ALTER TABLE shell_hosts FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON shell_hosts
        USING ((SELECT rank FROM realms WHERE slug = shell_hosts.realm) <= app_clearance_rank());
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON shell_hosts"
    drop_table :shell_hosts
  end
end
