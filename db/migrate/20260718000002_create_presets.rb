class CreatePresets < ActiveRecord::Migration[8.1]
  def change
    create_table :presets do |t|
      t.string :key, null: false, index: { unique: true }
      t.string :name, null: false
      t.jsonb :stages, null: false, default: [] # ordered [{name:, enabled:, budget:}]
      t.jsonb :params, null: false, default: {} # provider params (temperature, ...)
      t.timestamps
    end
  end
end
