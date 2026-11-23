# A person changing a held grant's effect (allow, review, confirm, deny)
# from the admin page is on the record with its other changes: both set
# only when the effect moved.
class AddEffectToGuidanceChanges < ActiveRecord::Migration[8.1]
  def change
    add_column :guidance_changes, :old_effect, :string
    add_column :guidance_changes, :new_effect, :string
  end
end
