# A persona with a life between conversations (MELUZINA.md, "A persona's
# life"): the instruction her life turns run under, the odds by hour, where
# her whispers land, and how often they may. Off while empty.
class AddLifeToPersonas < ActiveRecord::Migration[8.1]
  def change
    add_column :personas, :life, :jsonb, null: false, default: {}
  end
end
