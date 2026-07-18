class CreateHobSchema < ActiveRecord::Migration[8.1]
  # Tables marked [RLS] in DESIGN.md get row-level security from day one, even
  # though only one realm is exercised initially. Policies are FORCEd so they
  # bind the table owner too — the app connects as the owning role.
  RLS_TABLES = %w[conversations message_nodes prompt_snapshots].freeze

  def up
    enable_extension "vector"

    create_table :realms, id: false do |t|
      t.string :slug, null: false, primary_key: true
      t.integer :rank, null: false, index: { unique: true }
    end

    create_table :principals do |t|
      t.string :kind, null: false # human | persona | worker | surface
      t.string :name, null: false, index: { unique: true }
      t.string :max_clearance, null: false
      t.timestamps
    end

    create_table :api_keys do |t|
      t.string :token_digest, null: false, index: { unique: true }
      t.references :principal, null: false, foreign_key: true
      t.string :surface, null: false
      t.string :default_clearance, null: false
      t.datetime :last_used_at
      t.timestamps
    end

    create_table :providers do |t|
      t.string :slug, null: false, index: { unique: true }
      t.string :kind, null: false # anthropic | openai_compat
      t.jsonb :config, null: false, default: {}
      t.boolean :transient, null: false, default: false
      t.timestamps
    end

    create_table :model_roles do |t|
      t.string :role, null: false, index: { unique: true }
      t.jsonb :chain, null: false, default: [] # ordered [{provider:, model:, params:}]
      t.timestamps
    end

    create_table :conversations, id: :string do |t|
      t.string :surface, null: false
      t.string :realm, null: false
      t.string :taint_realm, null: false
      t.string :title
      t.timestamps
    end

    create_table :message_nodes, id: false do |t|
      t.string :content_hash, null: false, primary_key: true
      t.string :conversation_id, null: false, index: true
      t.string :parent_hash, index: true
      t.string :realm, null: false # denormalized from conversation so policies stay self-contained
      t.string :role, null: false # user | assistant | system | event
      t.string :speaker
      t.string :kind, null: false, default: "text" # text | tool_call | tool_result | event
      t.text :content, null: false
      t.jsonb :meta, null: false, default: {} # usage, model, stop reason
      t.string :prompt_snapshot_hash
      t.datetime :created_at, null: false
    end

    create_table :branches do |t|
      t.string :conversation_id, null: false
      t.string :name, null: false
      t.string :head_hash, null: false
      t.timestamps
      t.index [ :conversation_id, :name ], unique: true
    end

    create_table :personas, id: :string do |t|
      t.string :key, null: false, index: { unique: true }
      t.string :name, null: false
      t.jsonb :prompt, null: false, default: {} # system_core, greetings, examples
      t.string :model_role
      t.string :voice_id
      t.jsonb :card_import
      t.timestamps
    end

    create_table :prompt_snapshots, id: false do |t|
      t.string :digest, null: false, primary_key: true
      t.string :conversation_id, null: false, index: true
      t.string :realm, null: false
      t.jsonb :assembled, null: false
      t.datetime :created_at, null: false
    end

    create_table :usage_events do |t|
      t.references :principal, foreign_key: true
      t.string :surface
      t.string :role
      t.string :provider
      t.string :model
      t.jsonb :units, null: false, default: {} # input_tokens, output_tokens, characters, seconds
      t.decimal :cost, precision: 10, scale: 6
      t.string :ref
      t.datetime :created_at, null: false
    end

    # Fail-closed clearance: unset app.clearance -> NULL rank -> no rows visible.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION app_clearance_rank() RETURNS integer
      LANGUAGE sql STABLE AS $$
        SELECT rank FROM realms WHERE slug = current_setting('app.clearance', true)
      $$;
    SQL

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
    execute "DROP FUNCTION IF EXISTS app_clearance_rank()"
    drop_table :usage_events
    drop_table :prompt_snapshots
    drop_table :personas
    drop_table :branches
    drop_table :message_nodes
    drop_table :conversations
    drop_table :model_roles
    drop_table :providers
    drop_table :api_keys
    drop_table :principals
    drop_table :realms
  end
end
