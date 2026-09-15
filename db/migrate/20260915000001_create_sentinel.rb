# The sentinel (SENTINEL.md): the gate through which less-trusted external
# agents ask hob for information and privileged actions, and the mission
# queue through which the household hands work to agents that can only make
# outbound connections.
#
# capabilities       what can be asked for: native handlers, surface webhooks,
#                    or work a poller leases (venue: native | webhook | poll)
# sentinel_policies  per-agent rules: allow | deny | review | confirm, with
#                    argument constraints and rate/cost limits
# sentinel_requests  every ask, its decision, and its outcome — the audit log
# missions           work addressed to a principal, leased by polling
class CreateSentinel < ActiveRecord::Migration[8.1]
  RLS_TABLES = %w[sentinel_requests missions].freeze

  def up
    create_table :capabilities do |t|
      t.string :name, null: false, index: { unique: true } # "hob.complete", "mise.add_to_shopping_list"
      t.text :description, null: false
      t.jsonb :input_schema, null: false, default: { "type" => "object", "properties" => {} }
      t.string :kind, null: false, default: "act"  # read | act
      t.string :realm, null: false                 # clearance an agent needs to ask for it
      t.string :venue, null: false                 # native | webhook | poll
      t.jsonb :config, null: false, default: {}    # native: handler; webhook: url, secret; poll: assignee
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    create_table :sentinel_policies do |t|
      t.references :principal, foreign_key: true  # NULL: applies to every agent
      t.string :capability, null: false, default: "*" # exact name or a glob ("hob.conversation.*")
      t.string :effect, null: false               # allow | deny | review | confirm
      t.jsonb :constraints, null: false, default: {} # { arg => { in: [], max:, pattern: } }
      t.jsonb :limits, null: false, default: {}   # { per_hour:, per_day:, cost_per_day: }
      t.text :guidance                            # what the reviewer is told
      t.timestamps
      t.index [ :principal_id, :capability ], unique: true
    end

    create_table :sentinel_requests, id: :string do |t|
      t.references :principal, null: false, foreign_key: true # the asking agent
      t.references :capability, null: false, foreign_key: true
      t.jsonb :arguments, null: false, default: {}
      t.text :reason
      t.string :surface, null: false              # the key's surface when it asked
      t.string :realm, null: false                # the agent's clearance when it asked
      t.string :status, null: false, default: "pending" # pending | executing | completed | failed | denied
      t.string :decision                          # allow | deny | escalate
      t.string :decided_by                        # policy | limit | constraint | realm | reviewer | human
      t.text :rationale
      t.references :decider, foreign_key: { to_table: :principals } # the human, when decided_by is human
      t.jsonb :review, null: false, default: {}   # the reviewer's verdict and its completion id
      t.jsonb :result
      t.text :error
      t.string :mission_id                        # the mission a poll-venue execution became
      t.string :on_mission_id                     # the mission the agent was working when it asked
      t.datetime :decided_at
      t.datetime :executed_at
      t.timestamps
      t.index [ :principal_id, :created_at ]
      t.index [ :status, :created_at ]
    end

    create_table :missions, id: :string do |t|
      t.references :assignee, null: false, foreign_key: { to_table: :principals }
      t.references :created_by, foreign_key: { to_table: :principals }
      t.string :title, null: false
      t.text :brief
      t.jsonb :payload, null: false, default: {}
      t.integer :priority, null: false, default: 0
      t.string :realm, null: false
      t.string :status, null: false, default: "queued" # queued | leased | completed | failed | cancelled
      t.integer :attempts, null: false, default: 0
      t.string :lease_token
      t.datetime :leased_at
      t.datetime :lease_expires_at
      t.jsonb :result
      t.text :error
      t.string :sentinel_request_id               # set when the mission fulfils a request
      t.timestamps
      t.index [ :assignee_id, :status, :priority, :created_at ], name: "index_missions_on_assignee_queue"
      t.index :sentinel_request_id
    end

    RLS_TABLES.each do |table|
      execute <<~SQL
        ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY;
        ALTER TABLE #{table} FORCE ROW LEVEL SECURITY;
        CREATE POLICY realm_visibility ON #{table}
          USING ((SELECT rank FROM realms WHERE slug = #{table}.realm) <= app_clearance_rank());
      SQL
    end
  end

  def down
    RLS_TABLES.each { |t| execute "DROP POLICY IF EXISTS realm_visibility ON #{t}" }
    drop_table :missions
    drop_table :sentinel_requests
    drop_table :sentinel_policies
    drop_table :capabilities
  end
end
