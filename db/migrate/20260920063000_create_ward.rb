# The ward (WARD.md): what hob keeps about the household's security posture.
# The inventory and policy stay in the infra repo (security/exposure.yaml);
# these tables hold what changes over time.
#
# ward_checks    a feed the ward expects to hear from on a cadence ("exposure")
# ward_runs      one posted report, its parsed lines, and what changed
# ward_findings  a WARN/FAIL/ERROR line that persists across runs, keyed by
#                fingerprint, with when it was first and last seen, when it
#                went away, and a person's acknowledgement with an expiry
# ward_notes     free text a person attaches to a subject (a host, a resource,
#                a check): the reviewed decisions, read back to the triage
#
# Not realm-scoped, like agent_messages: one class of data, read by people
# and by the personal-tier `ward.status` capability.
class CreateWard < ActiveRecord::Migration[8.1]
  def change
    create_table :ward_checks, id: false do |t|
      t.string :slug, null: false, primary_key: true     # "exposure"
      t.text :description, null: false, default: ""
      t.integer :interval_seconds, null: false, default: 7 * 24 * 3600  # expected cadence
      t.integer :grace_seconds, null: false, default: 24 * 3600         # slack before it is stale
      t.boolean :enabled, null: false, default: true
      t.datetime :last_completed_at                       # the last complete (exit 0/1) run
      t.string :last_run_id
      t.timestamps
    end

    create_table :ward_runs, id: :string do |t|
      t.string :check_slug, null: false
      t.references :principal, foreign_key: true          # who posted it (the worker), null for a sweep
      t.datetime :started_at
      t.datetime :finished_at
      t.integer :exit_code                                # 0 clean, 1 drift, 2 incomplete; null for a sweep
      t.boolean :complete, null: false, default: false    # only a complete run resolves findings
      t.jsonb :counts, null: false, default: {}           # { ok, warn, fail, error }
      t.jsonb :lines, null: false, default: []            # [[level, message], ...]
      t.jsonb :diff, null: false, default: {}             # { new:, reopened:, resolved:, expired_acks: [finding ids] }
      t.jsonb :triage                                     # { severity, headline, summary, next_steps, completion, model } or { error }
      t.string :mission_id                                # the ward.audit mission that ran it, if any
      t.datetime :created_at, null: false
      t.index [ :check_slug, :created_at ]
      t.foreign_key :ward_checks, column: :check_slug, primary_key: :slug
    end

    create_table :ward_findings, id: :string do |t|
      t.string :check_slug, null: false
      t.string :fingerprint, null: false                  # sha256(check, level, message)[0, 32]
      t.string :level, null: false                        # warn | fail | error
      t.string :subject, null: false                      # the message's leading "name:"
      t.text :message, null: false
      t.integer :occurrences, null: false, default: 1
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.string :first_run_id
      t.string :last_run_id
      t.datetime :resolved_at                             # a complete run no longer reported it
      t.string :resolved_run_id
      t.datetime :acknowledged_at                         # a person said "I know"
      t.references :acknowledged_by, foreign_key: { to_table: :principals }
      t.text :ack_note
      t.datetime :ack_until                               # the acknowledgement expires; null: until resolved
      t.timestamps
      t.index [ :check_slug, :fingerprint ], unique: true
      t.index [ :check_slug, :resolved_at ]
      t.foreign_key :ward_checks, column: :check_slug, primary_key: :slug
    end

    create_table :ward_notes, id: :string do |t|
      t.string :subject, null: false
      t.text :body, null: false
      t.references :author, foreign_key: { to_table: :principals }
      t.datetime :created_at, null: false
      t.index [ :subject, :created_at ]
    end
  end
end
