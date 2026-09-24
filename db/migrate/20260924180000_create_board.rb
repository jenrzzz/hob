# The household message board (SENTINEL.md, hob.board.read; the write side,
# hob.board.post, is a companion capability for a later review). One table:
# a thread is the (thread_id, thread_slug, thread_topic) a post carries,
# denormalized onto every post the way message_nodes denormalizes realm from
# conversations — the index is a GROUP BY, not a second table. Posts are
# immutable and append-only, so there is no updated_at.
class CreateBoard < ActiveRecord::Migration[8.1]
  def up
    create_table :board_posts, id: :string do |t|
      t.string :thread_id, null: false
      t.string :thread_slug, null: false
      t.string :thread_topic, null: false
      t.string :realm, null: false
      t.text :body, null: false
      t.jsonb :links, null: false, default: []
      t.references :sender_agent, null: false, foreign_key: { to_table: :principals }
      t.references :sender_principal, null: false, foreign_key: { to_table: :principals }
      t.datetime :created_at, null: false
      t.index [ :thread_id, :created_at ]
      t.index :thread_slug
    end

    execute <<~SQL
      ALTER TABLE board_posts ENABLE ROW LEVEL SECURITY;
      ALTER TABLE board_posts FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON board_posts
        USING ((SELECT rank FROM realms WHERE slug = board_posts.realm) <= app_clearance_rank());
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON board_posts"
    drop_table :board_posts
  end
end
