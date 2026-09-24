# hob.board.read shipped requiring sender_principal ("the person the agent
# spoke for") on every post. hob.board.post, built in parallel, found that
# column undeliverable — nothing in the request path can verifiably derive
# who a person is on the other end of an agent, only which surface the
# request came in on. The steward's call: drop sender_principal from the
# contract, add surface (matching hob.board.post's shape) in its place.
class DropBoardPostsSenderPrincipal < ActiveRecord::Migration[8.1]
  def up
    remove_reference :board_posts, :sender_principal, foreign_key: { to_table: :principals }
    add_column :board_posts, :surface, :string, null: false
  end

  def down
    remove_column :board_posts, :surface
    add_reference :board_posts, :sender_principal, null: false, foreign_key: { to_table: :principals }
  end
end
