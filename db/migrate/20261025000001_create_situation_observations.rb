# A person's present moment (SITUATION.md): short-lived, append-only
# observations of facets such as location and availability, plus topics.
#
# `txid` and `seq` are included from the start for situation.changes. The
# first slice does not expose that feed yet, but adding ordering after writers
# exist would make an otherwise avoidable cursor boundary.
class CreateSituationObservations < ActiveRecord::Migration[8.1]
  def up
    create_table :situation_observations, id: :string do |t|
      t.references :person, null: false, foreign_key: { to_table: :principals }, index: false
      t.string :kind, null: false
      t.string :slot
      t.jsonb :value, null: false, default: {}
      t.string :realm, null: false
      t.string :basis, null: false
      t.jsonb :source, null: false, default: {}
      t.datetime :observed_at, null: false
      t.datetime :expires_at, null: false
      t.datetime :ended_at
      t.references :ended_by, foreign_key: { to_table: :principals }
      t.bigint :txid, null: false, default: -> { "(pg_current_xact_id()::text)::bigint" }
      t.bigserial :seq, null: false
      t.datetime :created_at, null: false

      t.index [ :person_id, :kind, :realm, :slot, :observed_at ],
              name: "index_situation_current"
      t.index [ :person_id, :txid, :seq ], name: "index_situation_changes"
      t.index :observed_at
    end

    execute <<~SQL
      ALTER TABLE situation_observations ENABLE ROW LEVEL SECURITY;
      ALTER TABLE situation_observations FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON situation_observations
        USING ((SELECT rank FROM realms WHERE slug = situation_observations.realm) <= app_clearance_rank());
    SQL

    # Existing installations already have a materialized default preset.
    # Put the new volatile stage immediately before instruction; new installs
    # receive the same order from seeds.
    if (preset = select_one("SELECT id, stages FROM presets WHERE key = 'default'"))
      raw_stages = preset.fetch("stages")
      stages = raw_stages.is_a?(String) ? JSON.parse(raw_stages) : raw_stages
      unless stages.any? { |stage| stage["name"] == "situation" }
        at = stages.index { |stage| stage["name"] == "instruction" } || stages.length
        stages.insert(at, { "name" => "situation", "enabled" => true, "budget" => 400 })
        execute "UPDATE presets SET stages = #{connection.quote(stages.to_json)}, updated_at = CURRENT_TIMESTAMP " \
                "WHERE id = #{connection.quote(preset.fetch('id'))}"
      end
    end
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON situation_observations"
    drop_table :situation_observations
  end
end
