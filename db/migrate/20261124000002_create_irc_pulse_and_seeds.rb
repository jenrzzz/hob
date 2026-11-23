# A channel's pulse and its seed tray (IRC.md, "The pulse"): when a room goes
# quiet or turns into the same two voices, its host persona is woken to drop
# something in, picked from seeds a surface mined for it.
#
# irc_channels.pulse        { host, quiet_minutes, loop_lines, loop_nicks, gap_minutes, per_day }; null is no pulse
# irc_channels.pulse_state  { last_at, fired: [times in the last day], reason }
# irc_seeds                 things worth reacting to, kept at the channel's realm; taken once
class CreateIrcPulseAndSeeds < ActiveRecord::Migration[8.1]
  def up
    add_column :irc_channels, :pulse, :jsonb
    add_column :irc_channels, :pulse_state, :jsonb, null: false, default: {}

    create_table :irc_seeds do |t|
      t.references :irc_channel, null: false, foreign_key: true
      t.string :realm, null: false
      t.string :kind, null: false                     # archive | library | prompt | ...: what it is, said by whoever mined it
      t.string :title
      t.text :body, null: false
      t.string :key                                   # the miner's own id for it, so the same thing is never seeded twice
      t.jsonb :source, null: false, default: {}
      t.references :taken_by, null: true, foreign_key: { to_table: :principals }
      t.datetime :taken_at
      t.timestamps
      t.index %i[irc_channel_id key], unique: true, where: "key IS NOT NULL"
      t.index %i[irc_channel_id taken_at]
    end

    execute <<~SQL
      ALTER TABLE irc_seeds ENABLE ROW LEVEL SECURITY;
      ALTER TABLE irc_seeds FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON irc_seeds
        USING ((SELECT rank FROM realms WHERE slug = irc_seeds.realm) <= app_clearance_rank());
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON irc_seeds"
    drop_table :irc_seeds
    remove_column :irc_channels, :pulse_state
    remove_column :irc_channels, :pulse
  end
end
