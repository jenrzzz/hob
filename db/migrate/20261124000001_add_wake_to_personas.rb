# A persona's wakes on hob's IRC (IRC.md, "Woken"): the one wake pending
# (when it runs, and who named her where, by channel id and nick), and when
# she was woken in the last day, for the budget. Not her memory: a
# scheduler's state, like a job's.
class AddWakeToPersonas < ActiveRecord::Migration[8.1]
  def change
    add_column :personas, :wake, :jsonb, null: false, default: {}
  end
end
