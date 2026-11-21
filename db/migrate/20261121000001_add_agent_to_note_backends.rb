# A note backend may be one agent's own library (NOTES.md, "An agent's own
# folder"): a quire key scoped to one folder, given to one agent. Realm alone
# cannot say this, since the agent's clearance is often the same as its
# person's (meluzina, `personal`, beside jenner-notes). With `agent` set, the
# row is reachable by that agent and by people, and that agent reaches no
# other library. Notes.backends enforces it; null keeps a row as it was.
class AddAgentToNoteBackends < ActiveRecord::Migration[8.1]
  def change
    add_reference :note_backends, :agent, foreign_key: { to_table: :principals }, null: true
  end
end
