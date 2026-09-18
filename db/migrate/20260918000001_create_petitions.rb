# Petitions (SENTINEL.md, "Petitions and the forge"): an agent asking for a
# capability it does not have — an existing one it lacks a rule for, or one
# hob does not yet offer. The steward decides: grant a policy, dispatch a
# build to the forge, refer to a person, or deny. Every petition is a row,
# never deleted; like sentinel_requests it is the audit trail.
class CreatePetitions < ActiveRecord::Migration[8.1]
  def up
    create_table :petitions, id: :string do |t|
      t.references :principal, null: false, foreign_key: true # the asking agent
      t.text :want, null: false                    # what the agent wants to be able to do, in its words
      t.string :capability_name                    # suggested by the agent, then the one granted or proposed
      t.jsonb :arguments, null: false, default: {} # an example of the arguments it would send
      t.text :reason
      t.string :surface, null: false
      t.string :realm, null: false                 # the agent's clearance when it asked
      t.string :on_mission_id                      # the mission it was working when it asked
      t.string :status, null: false, default: "pending" # pending | granted | building | proposed | denied | failed
      t.string :action                             # grant | build | refer | deny
      t.string :decided_by                         # policy | limit | steward | human
      t.text :rationale
      t.references :decider, foreign_key: { to_table: :principals }
      t.jsonb :review, null: false, default: {}    # the steward's verdict and its completion id
      t.string :effect                             # the policy effect granted or to grant once built
      t.jsonb :spec, null: false, default: {}      # the drafted capability, when action is build
      t.references :sentinel_policy, foreign_key: true # the rule a grant created
      t.string :mission_id                         # the build mission
      t.string :pull_request                       # the forge's PR URL
      t.text :error
      t.datetime :decided_at
      t.datetime :settled_at
      t.timestamps
      t.index [ :principal_id, :created_at ]
      t.index [ :status, :created_at ]
      t.index :capability_name
      t.index :mission_id
    end

    execute <<~SQL
      ALTER TABLE petitions ENABLE ROW LEVEL SECURITY;
      ALTER TABLE petitions FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON petitions
        USING ((SELECT rank FROM realms WHERE slug = petitions.realm) <= app_clearance_rank());
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON petitions"
    drop_table :petitions
  end
end
