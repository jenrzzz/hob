# A reply that stopped normally (end_turn, stop) with no text and no tool call
# was metered as `refused`. It is its own status now, `empty`
# (Gateway::Response#empty?); relabel the rows that already say so. A row
# with no stop reason can't be told apart and stays a refusal.
class RelabelEmptyReplies < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      UPDATE usage_events SET status = 'empty'
      WHERE status = 'refused' AND error IS NULL AND stop_reason IS NOT NULL
        AND stop_reason NOT IN ('refusal', 'content_filter')
    SQL
  end

  def down
    execute "UPDATE usage_events SET status = 'refused' WHERE status = 'empty'"
  end
end
