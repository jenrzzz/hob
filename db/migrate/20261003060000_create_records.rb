# What the household's agents keep (RECORDS.md).
#
# record_collections  a named collection: whose, what realm, where its
#                     documents' keys are, and the schema they meet
# records             the current version of each document, one per key
# record_versions     every version, the current one included, with who
#                     wrote it, through what, and why
#
# All three are realm-scoped. A record's realm is its collection's, copied
# onto the row so RLS filters it without a join; a collection's realm never
# changes, so the copy cannot drift.
#
# record_versions.txid (the writing transaction's id, as a bigint) and .seq
# are the changes cursor: a version is handed
# out by Records.changes only once every transaction older than its own has
# finished, so a reader never steps past a version that commits late.
class CreateRecords < ActiveRecord::Migration[8.1]
  def up
    create_table :record_collections, id: :string do |t|
      t.string :name, null: false, index: { unique: true } # unique even once retracted, until purged
      t.references :principal, null: false, foreign_key: true # the owner: a person
      t.string :realm, null: false
      t.string :key_path, null: false             # a top-level field of every document
      t.jsonb :schema                             # a JSON Schema, or null
      t.integer :schema_version, null: false, default: 1
      t.text :description, null: false
      t.jsonb :notify, null: false, default: {}
      t.references :proposed_by, foreign_key: { to_table: :principals } # the agent that asked for it
      t.string :sentinel_request_id
      t.datetime :retracted_at
      t.references :retracted_by, foreign_key: { to_table: :principals }
      t.timestamps
    end

    create_table :records, id: :string do |t|
      t.references :collection, null: false, type: :string, foreign_key: { to_table: :record_collections }, index: false
      t.string :realm, null: false
      t.string :key, null: false
      t.integer :version, null: false
      t.integer :schema_version, null: false
      t.jsonb :data, null: false
      t.string :links, array: true, null: false, default: []
      t.datetime :observed_at, null: false
      t.text :source
      t.references :written_by, null: false, foreign_key: { to_table: :principals }
      t.string :surface
      t.datetime :retracted_at
      t.virtual :document, type: :tsvector, stored: true,
                           as: %q(jsonb_to_tsvector('simple'::regconfig, data, '["string", "numeric"]'::jsonb))
      t.timestamps
      t.index [ :collection_id, :key ], unique: true
      t.index [ :collection_id, :updated_at ]
      t.index :data, using: :gin, opclass: :jsonb_path_ops
      t.index :links, using: :gin
      t.index :document, using: :gin
    end

    create_table :record_versions, id: :string do |t|
      t.references :record, null: false, type: :string, foreign_key: true, index: false
      t.references :collection, null: false, type: :string, foreign_key: { to_table: :record_collections }, index: false
      t.string :realm, null: false
      t.integer :version, null: false
      t.integer :schema_version, null: false
      t.jsonb :data, null: false
      t.string :links, array: true, null: false, default: []
      t.datetime :observed_at, null: false
      t.text :source
      t.boolean :retracted, null: false, default: false
      t.text :reason                               # why it was retracted or restored
      t.references :principal, null: false, foreign_key: true # the writer, from the request
      t.string :surface
      t.string :sentinel_request_id
      t.string :mission_id
      t.bigint :txid, null: false, default: -> { "(pg_current_xact_id()::text)::bigint" }
      t.bigserial :seq, null: false
      t.datetime :created_at, null: false
      t.index [ :record_id, :version ], unique: true
      t.index [ :collection_id, :txid, :seq ]
    end

    %w[record_collections records record_versions].each do |table|
      execute <<~SQL
        ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY;
        ALTER TABLE #{table} FORCE ROW LEVEL SECURITY;
        CREATE POLICY realm_visibility ON #{table}
          USING ((SELECT rank FROM realms WHERE slug = #{table}.realm) <= app_clearance_rank());
      SQL
    end
  end

  def down
    %w[record_versions records record_collections].each do |table|
      execute "DROP POLICY IF EXISTS realm_visibility ON #{table}"
      drop_table table
    end
  end
end
