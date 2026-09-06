# Ledger v2 + pipeline conversations (EXTRACTION.md A5, A7, B1).
#
# usage_events: every gateway attempt writes a row, including failures.
# model_prices: cost is config (USD per million tokens), never code.
# conversations.kind: completions persist as `pipeline` conversations.
# model_roles.chain links gain `strict` (a jsonb key, no column change).
class LedgerV2AndPipelineConversations < ActiveRecord::Migration[8.1]
  def change
    change_table :usage_events do |t|
      t.string :operation                       # surface-defined: "interview.ask", "recipe.extract"
      t.string :status, null: false, default: "success" # success | refused | rate_limited | error
      t.integer :duration_ms
      t.text :error
      t.jsonb :metadata, null: false, default: {}
      t.string :snapshot_digest                 # prompt_snapshots.digest; replaces prompt/response bodies
      t.index :created_at
      t.index :ref
      t.index [ :role, :created_at ]
    end

    create_table :model_prices, id: false do |t|
      t.string :model, null: false, primary_key: true # exact id or prefix ("claude-haiku-4-5")
      t.decimal :input, precision: 10, scale: 4, null: false, default: 0       # USD per 1M input tokens
      t.decimal :output, precision: 10, scale: 4, null: false, default: 0      # USD per 1M output tokens
      t.decimal :cache_read, precision: 10, scale: 4, null: false, default: 0  # USD per 1M cache-read tokens
      t.decimal :cache_write, precision: 10, scale: 4, null: false, default: 0 # USD per 1M cache-creation tokens
      t.timestamps
    end

    add_column :conversations, :kind, :string, null: false, default: "chat" # chat | pipeline
    add_index :conversations, [ :kind, :updated_at ]
  end
end
