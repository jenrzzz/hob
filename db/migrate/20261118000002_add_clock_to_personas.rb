# A persona that lives across days knows what time it is and how long it has
# been (MELUZINA.md, "The clock"): her zones, the gap that counts as time
# drifting, and the dates she keeps. Off while empty.
class AddClockToPersonas < ActiveRecord::Migration[8.1]
  def change
    add_column :personas, :clock, :jsonb, null: false, default: {}
  end
end
