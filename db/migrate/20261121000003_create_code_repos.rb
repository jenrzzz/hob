# Repos an agent may commission work in (CODE.md): a GitHub repo that is one
# agent's own workshop, where Claude Code writes for it on the forge.
#
# code_repos   one repo, the agent it is kept for, who answers for it, and
#              the realm of what is in it
#
# Realm-scoped like shell_hosts. The commissions themselves are missions.
class CreateCodeRepos < ActiveRecord::Migration[8.1]
  def up
    create_table :code_repos, id: :string do |t|
      t.string :name, null: false, index: { unique: true } # "meluzina-box"
      t.string :repo, null: false                 # "owner/name" on GitHub
      t.references :principal, null: false, foreign_key: true # who answers for it: a person
      t.references :agent, null: false, foreign_key: { to_table: :principals } # whose workshop it is
      t.string :realm, null: false                # of everything in it, briefs included
      t.string :about                             # free text the agent reads: where it is cloned, what it is for
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE code_repos ENABLE ROW LEVEL SECURITY;
      ALTER TABLE code_repos FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON code_repos
        USING ((SELECT rank FROM realms WHERE slug = code_repos.realm) <= app_clearance_rank());
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON code_repos"
    drop_table :code_repos
  end
end
