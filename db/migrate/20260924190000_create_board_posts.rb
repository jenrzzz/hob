# hob.board.post was built against its own board_posts table, independent
# of hob.board.read's (this branch had not yet seen 20260924180000 or
# 20260924190500 when it was written). The steward's reconciliation kept
# read's table — thread_id/thread_slug/thread_topic, plus surface in place
# of sender_principal (20260924190500) — so there is nothing left for this
# migration to do; it stays only to hold its place in migration history.
class CreateBoardPosts < ActiveRecord::Migration[8.1]
  def up
  end

  def down
  end
end
