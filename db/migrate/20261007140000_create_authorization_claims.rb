# User-authorization claims (SENTINEL.md, "User-authorization claims"): an
# agent attaching "the user already said yes in chat, here's the quote" to a
# request that would otherwise wait on a person's tap. hob cannot verify a
# quote, so the design is deterrence plus audit plus spot-checks —
# authorization_claims is the audit log, logged whether or not the claim
# ended up mattering, and never deleted.
#
# Trust consequences (a spot-check the user fails) land on the agent, not a
# new table: capabilities_frozen_at/_reason hold every one of its requests
# at `policy` until a person reviews and clears it; claim_scrutiny_remaining
# counts down the forced spot-checks owed after a failed check.
#
# Realm-scoped like sentinel_requests: a claim carries the request's realm,
# so a quote from a personal chat is no more visible than the request it backs.
class CreateAuthorizationClaims < ActiveRecord::Migration[8.1]
  def up
    create_table :authorization_claims, id: :string do |t|
      t.references :principal, null: false, foreign_key: true        # the claiming agent
      t.references :sentinel_request, null: false, foreign_key: true, type: :string
      t.text :quote                       # the exact verbatim message text, as the agent gave it
      t.datetime :quoted_at               # when the agent says the user said it
      t.text :context                     # one line: what the agent proposed just before the message
      t.text :interpretation              # what the agent believes the message authorizes, in its own words
      t.string :action_ref                # the request id, or the capability + args, the claim supports
      t.string :realm, null: false        # the request's
      t.string :status, null: false, default: "rejected"
      # rejected | unused | insufficient | backed | spot_checked | confirmed | declined | fabricated
      t.text :rejection_reason            # set when status is "rejected": which intake check failed
      t.jsonb :rubric, null: false, default: {} # the five-check verdict, its rationale, and the completion id
      t.jsonb :spot_check, null: false, default: {} # reason, fired_at, and (once settled) resolved_by/resolved_at
      t.datetime :decided_at              # nil while a spot-check awaits a person
      t.timestamps
      t.index [ :principal_id, :created_at ]
      t.index :status
    end

    execute <<~SQL
      ALTER TABLE authorization_claims ENABLE ROW LEVEL SECURITY;
      ALTER TABLE authorization_claims FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON authorization_claims
        USING ((SELECT rank FROM realms WHERE slug = authorization_claims.realm) <= app_clearance_rank());
    SQL

    add_column :principals, :capabilities_frozen_at, :datetime
    add_column :principals, :capabilities_freeze_reason, :text
    add_column :principals, :claim_scrutiny_remaining, :integer, null: false, default: 0
  end

  def down
    remove_column :principals, :claim_scrutiny_remaining
    remove_column :principals, :capabilities_freeze_reason
    remove_column :principals, :capabilities_frozen_at
    execute "DROP POLICY IF EXISTS realm_visibility ON authorization_claims"
    drop_table :authorization_claims
  end
end
