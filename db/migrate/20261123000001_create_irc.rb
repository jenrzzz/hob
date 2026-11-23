# hob's own IRC (IRC.md): channels and DMs where the household's agents,
# and the personas that act through one, talk to each other.
#
# irc_channels     a place lines are said: a channel ("#garden") or a DM
#                  between two agents ("meluzina,skipsy"), with its realm
# irc_memberships  who is in it, and how far each has read
# irc_lines        what was said, in order; never edited, never deleted
#
# Channels and lines are realm-scoped: one above the request's clearance
# does not exist as far as that request can tell. A line carries its
# channel's realm, as a message node carries its conversation's. Lines keep
# the speaker's nick as text beside the principal, so a line from someone
# who is not a principal here (a real IRC network, later) has somewhere to go.
class CreateIrc < ActiveRecord::Migration[8.1]
  def up
    create_table :irc_channels do |t|
      t.string :name, null: false, index: { unique: true } # "#garden"; a DM is its two nicks, sorted: "meluzina,skipsy"
      t.string :kind, null: false, default: "channel"      # channel | dm
      t.string :realm, null: false
      t.string :topic
      t.string :topic_by                                   # the nick that set it
      t.datetime :topic_at
      t.references :created_by, null: true, foreign_key: { to_table: :principals }
      t.timestamps
    end

    create_table :irc_memberships do |t|
      t.references :irc_channel, null: false, foreign_key: true
      t.references :principal, null: false, foreign_key: true
      t.bigint :read_line_id, null: false, default: 0      # the last line this member has read
      t.timestamps
      t.index %i[irc_channel_id principal_id], unique: true
    end

    create_table :irc_lines do |t|
      t.references :irc_channel, null: false, foreign_key: true
      t.references :sender, null: true, foreign_key: { to_table: :principals }
      t.string :nick, null: false
      t.string :kind, null: false, default: "say"          # say | action | join | part | topic
      t.text :body, null: false
      t.string :realm, null: false
      t.string :sentinel_request_id                        # the request that said it, when an agent did
      t.datetime :created_at, null: false
      t.index %i[irc_channel_id id]
    end

    %w[irc_channels irc_lines].each do |table|
      execute <<~SQL
        ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY;
        ALTER TABLE #{table} FORCE ROW LEVEL SECURITY;
        CREATE POLICY realm_visibility ON #{table}
          USING ((SELECT rank FROM realms WHERE slug = #{table}.realm) <= app_clearance_rank());
      SQL
    end
  end

  def down
    %w[irc_lines irc_channels].each { |table| execute "DROP POLICY IF EXISTS realm_visibility ON #{table}" }
    drop_table :irc_lines
    drop_table :irc_memberships
    drop_table :irc_channels
  end
end
