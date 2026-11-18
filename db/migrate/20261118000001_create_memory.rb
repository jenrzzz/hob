# The memory plane, v1 (MEMORY.md): entities, observations about them,
# image bytes kept beside the DAG, and a persona's versioned sheet.
#
# Entities are realm-less (DESIGN.md, plane 3): a name and a type, nothing a
# reader learns anything sensitive from. Everything said *about* an entity is
# an observation, which carries a realm and is filtered by RLS like
# message_nodes. Observations are never rewritten: a correction is a new row
# that supersedes the old one, and only the lifecycle columns of the old row
# (superseded_by_id, retired_*) ever change.
class CreateMemory < ActiveRecord::Migration[8.1]
  def up
    create_table :entities, id: :string do |t|
      t.string :kind, null: false                    # free-form type: person, persona, work, place, ...
      t.string :name, null: false
      t.string :aliases, array: true, null: false, default: []
      t.string :ref                                  # "principal:jenner", "persona:meluzina", "kat:media:30880"
      t.string :created_by
      t.timestamps

      t.index :ref, unique: true
      t.index [ :kind, :name ]
      t.index :aliases, using: :gin
    end

    add_column :personas, :entity_id, :string
    add_foreign_key :personas, :entities
    add_index :personas, :entity_id, unique: true
    # { recall: bool, tools: bool, budget: int, about: [refs] } — off unless set.
    add_column :personas, :memory, :jsonb, null: false, default: {}

    create_table :observations, id: :string do |t|
      t.references :entity, type: :string, null: false, foreign_key: true, index: false
      t.references :author_entity, type: :string, foreign_key: { to_table: :entities }, index: false
      t.string :kind, null: false, default: "note"
      t.text :body, null: false
      t.string :realm, null: false
      # Provenance: who wrote it (request principal, never an argument),
      # through which surface, from which conversation and node.
      t.references :principal, foreign_key: true, index: false
      t.string :surface, null: false
      t.string :conversation_id
      t.string :node_hash
      t.string :evidence, array: true, null: false, default: []
      t.jsonb :source, null: false, default: {}
      t.datetime :observed_at, null: false
      t.column :embedding, :vector
      t.string :embedding_model
      t.string :supersedes_id
      t.string :superseded_by_id
      t.datetime :retired_at
      t.string :retired_by
      t.text :retire_reason
      t.virtual :document, type: :tsvector, as: "to_tsvector('english'::regconfig, body)", stored: true
      t.bigint :txid, null: false, default: -> { "(pg_current_xact_id()::text)::bigint" }
      t.bigserial :seq, null: false
      t.datetime :created_at, null: false

      t.index [ :entity_id, :observed_at ], where: "retired_at IS NULL AND superseded_by_id IS NULL",
                                            name: "index_observations_current_by_entity"
      t.index [ :author_entity_id, :entity_id, :observed_at ], name: "index_observations_file"
      t.index :document, using: :gin
      t.index :evidence, using: :gin
      t.index :supersedes_id
      t.index [ :txid, :seq ], name: "index_observations_changes"
    end

    # Image (and other binary) content of messages and tool results. Nodes
    # carry the digest; the bytes live here once per realm.
    create_table :blobs, primary_key: [ :realm, :digest ] do |t|
      t.string :realm, null: false
      t.string :digest, null: false
      t.string :media_type, null: false
      t.binary :bytes, null: false
      t.integer :size, null: false
      t.datetime :created_at, null: false

      t.index :digest
    end
    add_column :message_nodes, :attachments, :jsonb, null: false, default: []

    create_table :persona_sheet_revisions, id: :string do |t|
      t.references :persona, type: :string, null: false, foreign_key: true, index: false
      # Versions and apply order come from sequences shared by every persona
      # and realm, so a gap tells a reader nothing about whose sheet changed
      # at a realm they cannot see.
      t.bigserial :version, null: false
      t.string :kind, null: false, default: "edit"   # edit | rollback
      t.string :realm, null: false
      t.jsonb :ops, null: false, default: []
      t.text :rationale
      t.string :citations, array: true, null: false, default: []
      t.string :status, null: false, default: "proposed" # proposed | applied | rejected | reverted
      t.references :proposed_by, foreign_key: { to_table: :principals }, index: false
      t.string :proposed_via, null: false              # the surface, or "accretion"
      t.jsonb :provenance, null: false, default: {}    # accretion: conversation, snapshot, model
      t.bigint :rollback_to
      t.references :decided_by, foreign_key: { to_table: :principals }, index: false
      t.datetime :decided_at
      t.bigint :applied_seq
      t.string :reverted_by_id
      t.datetime :created_at, null: false

      t.index [ :persona_id, :version ], unique: true
      t.index [ :persona_id, :status, :applied_seq ]
    end

    execute "CREATE SEQUENCE persona_sheet_applied_seq"

    %w[observations blobs persona_sheet_revisions].each do |table|
      execute <<~SQL
        ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY;
        ALTER TABLE #{table} FORCE ROW LEVEL SECURITY;
        CREATE POLICY realm_visibility ON #{table}
          USING ((SELECT rank FROM realms WHERE slug = #{table}.realm) <= app_clearance_rank());
      SQL
    end
  end

  def down
    %w[observations blobs persona_sheet_revisions].each { |t| execute "DROP POLICY IF EXISTS realm_visibility ON #{t}" }
    drop_table :persona_sheet_revisions
    execute "DROP SEQUENCE IF EXISTS persona_sheet_applied_seq"
    remove_column :message_nodes, :attachments
    drop_table :blobs
    drop_table :observations
    remove_column :personas, :memory
    remove_index :personas, :entity_id
    remove_foreign_key :personas, :entities
    remove_column :personas, :entity_id
    drop_table :entities
  end
end
