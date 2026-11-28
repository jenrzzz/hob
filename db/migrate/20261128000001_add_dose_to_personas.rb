# A dose a persona has taken (MEMORY.md, "A dose"): its level, when she took
# it and how long it runs. Not her memory: the state her recall is in for a
# while, like a wake.
class AddDoseToPersonas < ActiveRecord::Migration[8.1]
  def change
    add_column :personas, :dose, :jsonb, null: false, default: {}
  end
end
