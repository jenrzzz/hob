# A price row is a fact about the outside world; say where it came from and
# when it took effect so a later correction is an audit, not a mystery.
class ModelPriceNotes < ActiveRecord::Migration[8.1]
  def change
    add_column :model_prices, :note, :string
    add_column :model_prices, :effective_from, :date
  end
end
