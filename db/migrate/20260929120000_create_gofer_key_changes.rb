# One edit to a gofer key's domain allowlist, made from the admin UI
# (BROWSE.md, gofer's admin-only PATCH /v1/keys/:name): who asked for it,
# when, which browser's gofer and which key, and the domains before and
# after. Never deleted, like guidance_changes: hob's own record of a
# household-admin operation gofer also audits on its own side.
class CreateGoferKeyChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :gofer_key_changes, id: :string do |t|
      t.references :browser, null: false, foreign_key: true, type: :string # which gofer (its url)
      t.string :key_name, null: false                # the gofer key's name, e.g. "hob"
      t.references :decider, null: false, foreign_key: { to_table: :principals } # the admin who made the change
      t.jsonb :domains_before                        # null: hob never learned the prior list
      t.jsonb :domains_after, null: false, default: [] # [] means unrestricted, as gofer treats it
      t.text :rationale
      t.timestamps
      t.index [ :browser_id, :key_name, :created_at ]
    end
  end
end
