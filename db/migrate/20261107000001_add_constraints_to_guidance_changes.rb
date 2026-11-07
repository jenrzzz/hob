# SENTINEL.md, "Policies": a grant's scope is its guidance and its argument
# constraints together. A petition (or a person) widening a held grant to a
# new collection changes the constraint, not just the words, so the change
# log records both. Rows from before this carry only guidance.
class AddConstraintsToGuidanceChanges < ActiveRecord::Migration[8.1]
  def change
    add_column :guidance_changes, :old_constraints, :jsonb
    add_column :guidance_changes, :new_constraints, :jsonb
  end
end
