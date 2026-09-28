# Guidance is reviewer-facing scope text on a sentinel_policies grant
# (SENTINEL.md, "Policies": "guidance is free text for the reviewer"). Until
# now nothing could change it after the grant: a petition to widen or narrow
# what an already-held capability's guidance permits had nowhere to land, so
# an approved widening just sat unapplied. guidance_changes is the audit
# trail for every edit to that text, wherever it comes from — a petition the
# steward or a person granted, or a person editing a grant directly in the
# admin UI — never deleted, like petitions and sentinel_requests.
class CreateGuidanceChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :guidance_changes, id: :string do |t|
      t.references :sentinel_policy, null: false, foreign_key: true
      t.references :petition, foreign_key: true, type: :string # set when source is "petition"
      t.string :source, null: false             # petition | admin
      t.string :decided_by, null: false          # steward | human
      t.references :decider, foreign_key: { to_table: :principals } # the person, when decided_by is human
      t.text :old_guidance
      t.text :new_guidance
      t.text :rationale
      t.timestamps
      t.index [ :sentinel_policy_id, :created_at ]
    end
  end
end
