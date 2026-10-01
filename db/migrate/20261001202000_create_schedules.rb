# Schedules (SCHEDULES.md): hob's clock. A schedule is a mission template
# and a cron line; when it comes due, hob queues the mission for its
# assignee, exactly as if someone had asked just then. The ward's weekly
# audit, an app's upkeep, an agent's "every morning at 7" are all rows.
#
# Realm-scoped like missions: a schedule's realm is the realm of every
# mission it queues, and a schedule above the request's clearance does not
# exist as far as that request can tell.
class CreateSchedules < ActiveRecord::Migration[8.1]
  def up
    create_table :schedules, id: :string do |t|
      t.string :name, null: false                 # "ward-exposure", unique per creator
      t.text :description, null: false, default: ""
      t.string :cron, null: false                 # fugit: "0 6 * * 1", "every day at 7am"
      t.string :time_zone, null: false, default: "Etc/UTC"
      t.references :assignee, null: false, foreign_key: { to_table: :principals }
      t.references :created_by, foreign_key: { to_table: :principals } # null: hob itself (a rake task)
      t.string :realm, null: false
      t.string :title, null: false                # of each mission
      t.text :brief
      t.jsonb :payload, null: false, default: {}
      t.integer :priority, null: false, default: 0
      t.boolean :enabled, null: false, default: true
      t.datetime :next_fire_at                    # null while disabled
      t.datetime :last_fired_at
      t.string :last_mission_id
      t.integer :fired_count, null: false, default: 0
      t.integer :skipped_count, null: false, default: 0 # came due while its last mission was still open
      t.datetime :last_skipped_at                 # a skip after the last fire starts a streak: one ping, not one per tick
      t.timestamps
      t.index [ :created_by_id, :name ], unique: true, nulls_not_distinct: true
      t.index [ :enabled, :next_fire_at ]
    end

    add_column :missions, :schedule_id, :string
    add_index :missions, :schedule_id

    execute <<~SQL
      ALTER TABLE schedules ENABLE ROW LEVEL SECURITY;
      ALTER TABLE schedules FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON schedules
        USING ((SELECT rank FROM realms WHERE slug = schedules.realm) <= app_clearance_rank());
    SQL
  end

  def down
    remove_index :missions, :schedule_id
    remove_column :missions, :schedule_id
    execute "DROP POLICY IF EXISTS realm_visibility ON schedules"
    drop_table :schedules
  end
end
