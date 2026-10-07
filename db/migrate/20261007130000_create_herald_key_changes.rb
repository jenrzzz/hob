# One edit to a herald key's permissions or scope, made from the admin UI
# (TEXTS.md; herald's admin-only PATCH /v1/keys/:name): who asked for it,
# when, which herald (by the text backend it was reached through) and which
# key, and the key before and after. Never deleted, like gofer_key_changes:
# hob's own record of a household-admin operation herald also audits on its
# own side.
class CreateHeraldKeyChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :herald_key_changes, id: :string do |t|
      t.references :text_backend, null: false, foreign_key: true, type: :string # which herald (its url)
      t.string :key_name, null: false                # the herald key's name, e.g. "hob-family"
      t.references :decider, null: false, foreign_key: { to_table: :principals } # the admin who made the change
      t.jsonb :key_before                            # { permissions, scope } as herald had it
      t.jsonb :key_after, null: false                # { permissions, scope } as herald has it now; a null scope is every chat
      t.text :rationale
      t.timestamps
      t.index [ :text_backend_id, :key_name, :created_at ]
    end
  end
end
