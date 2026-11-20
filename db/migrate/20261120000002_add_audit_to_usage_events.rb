# The ledger as an audit trail: enough to investigate a call, not just count
# it. usage_events stays realm-less (GET /v1/usage and the spend totals must
# see every row whatever the reader's clearance), so it gains only what says
# nothing sensitive: the realm the call's content belongs to, the provider's
# stop reason, and the names of the tools the model asked for.
#
# What the model actually said lives in usage_payloads, one row per event,
# realm-scoped by RLS like prompt_snapshots: the reply text, its thinking,
# its tool calls with their arguments, and — only for a call that carried no
# prompt snapshot — the request itself. This is the one place a refusal's
# prose or an unparseable structured reply survives; the DAG keeps neither.
class AddAuditToUsageEvents < ActiveRecord::Migration[8.1]
  def up
    add_column :usage_events, :realm, :string
    add_column :usage_events, :stop_reason, :string
    add_column :usage_events, :tool_names, :string, array: true, null: false, default: []
    add_index :usage_events, [ :status, :created_at ]
    add_index :usage_events, [ :operation, :created_at ]
    add_index :usage_events, :snapshot_digest

    # Keyed by the event's own id: no sequence of its own.
    create_table :usage_payloads, id: false do |t|
      t.bigint :usage_event_id, null: false
      t.foreign_key :usage_events, column: :usage_event_id, on_delete: :cascade
      t.string :realm, null: false
      t.jsonb :request         # { system, messages, tools, schema } — only when no snapshot holds it
      t.jsonb :response        # { content, reasoning, tool_calls }
      t.datetime :created_at, null: false
    end

    execute <<~SQL
      ALTER TABLE usage_payloads ADD PRIMARY KEY (usage_event_id);
      ALTER TABLE usage_payloads ENABLE ROW LEVEL SECURITY;
      ALTER TABLE usage_payloads FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON usage_payloads
        USING ((SELECT rank FROM realms WHERE slug = usage_payloads.realm) <= app_clearance_rank());
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON usage_payloads"
    drop_table :usage_payloads
    remove_index :usage_events, :snapshot_digest
    remove_index :usage_events, [ :operation, :created_at ]
    remove_index :usage_events, [ :status, :created_at ]
    remove_column :usage_events, :tool_names
    remove_column :usage_events, :stop_reason
    remove_column :usage_events, :realm
  end
end
