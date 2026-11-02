# PLUGINS.md, section 5 (Phase 0): a capability a surface adds on its own,
# with no person running the command, lands unaccepted and disabled. No
# rule (a wildcard included) reaches it and no waiting petition is granted
# on it until a person accepts it, confirming or changing the realm and
# kind it proposed. Every row that already exists was put there by a
# person (a merged PR, a by-hand registration), so it counts as accepted.
class AddAcceptanceToCapabilities < ActiveRecord::Migration[8.1]
  def up
    add_column :capabilities, :accepted_at, :datetime
    add_reference :capabilities, :accepted_by, foreign_key: { to_table: :principals }
    execute "UPDATE capabilities SET accepted_at = created_at"
  end

  def down
    remove_reference :capabilities, :accepted_by
    remove_column :capabilities, :accepted_at
  end
end
