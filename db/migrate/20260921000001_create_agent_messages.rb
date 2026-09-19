# Notes from one agent on this instance to another (SENTINEL.md,
# hob.agent.message): one row per send, never deleted. With the sentinel
# request that wrote it (sentinel_request_id), it is the household's audit
# trail of what one agent told another. Not realm-scoped: the capability
# is household-tier coordination and the recipient filter is the guard; a
# person reads the whole log with hob:messages.
class CreateAgentMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_messages, id: :string do |t|
      t.references :sender, null: false, foreign_key: { to_table: :principals }    # from: the asking agent
      t.references :recipient, null: false, foreign_key: { to_table: :principals } # to: a registered agent, never a person
      t.text :body, null: false                   # plain text, at most 500 characters
      t.string :sentinel_request_id, null: false  # the hob.agent.message request that sent it
      t.datetime :read_at                         # stamped when the recipient's inbox returned it
      t.timestamps
      t.index [ :recipient_id, :read_at, :created_at ], name: "index_agent_messages_on_inbox"
      t.index :sentinel_request_id
    end
  end
end
