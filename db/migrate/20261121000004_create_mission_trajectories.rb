# What Claude Code did on a mission (SENTINEL.md, "Trajectories"): its
# session files, as the forge handed them over with the mission's report.
#
# mission_trajectories   one session file of one mission: the session's id,
#                        the file's place among them (a subagent's sits under
#                        its session), and the file itself, gzipped
#
# A row is at its mission's realm: it holds the brief and everything the
# build read.
class CreateMissionTrajectories < ActiveRecord::Migration[8.1]
  def up
    create_table :mission_trajectories, id: :string do |t|
      t.string :mission_id, null: false
      t.string :realm, null: false
      t.integer :attempt, null: false, default: 1 # the mission's attempt this came from
      t.string :session, null: false              # Claude Code's session id
      t.string :path, null: false                 # "<session>.jsonl", or "<session>/subagents/<agent>.jsonl"
      t.integer :lines, null: false, default: 0
      t.integer :bytes, null: false, default: 0   # of the file, before gzip
      t.binary :body, null: false                 # the file, gzipped
      t.datetime :created_at, null: false
    end
    add_index :mission_trajectories, %i[mission_id path], unique: true
    add_foreign_key :mission_trajectories, :missions, on_delete: :cascade

    execute <<~SQL
      ALTER TABLE mission_trajectories ENABLE ROW LEVEL SECURITY;
      ALTER TABLE mission_trajectories FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON mission_trajectories
        USING ((SELECT rank FROM realms WHERE slug = mission_trajectories.realm) <= app_clearance_rank());
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON mission_trajectories"
    drop_table :mission_trajectories
  end
end
