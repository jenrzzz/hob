# Threats (THREATS.md): what the ward is *told*, matched against what it
# knows the household runs, defended at a tier it may act at, and closed
# only with evidence.
#
# ward_threats         a declared risk: a CVE, an advisory, an actor, an
#                      anomaly; its current state, with what it matched,
#                      what ward did about it, and how it was resolved
# ward_threat_events   the append-only history of each one: reported,
#                      merged, triaged, every transition, posture, note,
#                      indicator, pass, resolution, reopening
# ward_assets          the inventory: hosts, Coolify resources, the control
#                      plane, scan targets, with images and components
# ward_observations    what version of a component an asset was seen
#                      running, by whom, first and last seen: the evidence
#                      a resolution points at
#
# Not realm-scoped, like the rest of the ward: one class of data, read by
# people and by personal-tier capabilities.
class CreateWardThreats < ActiveRecord::Migration[8.1]
  def change
    create_table :ward_threats, id: :string do |t|
      t.string :kind, null: false                         # cve | advisory | actor | anomaly
      t.text :title, null: false
      t.string :cve_ids, array: true, null: false, default: []
      t.string :component                                 # what the CVE is in: "php"
      t.jsonb :fixed_versions, null: false, default: {}   # { "8.3" => "8.3.36", "8.4" => "8.4.27" }, or { "*" => "1.2.3" }
      t.jsonb :gotchas, null: false, default: []          # [{ text, satisfied_at?, satisfied_by?, evidence? }]
      t.jsonb :sources, null: false, default: []          # [{ type: person|agent|feed, ref, by, at }]
      t.references :reported_by, foreign_key: { to_table: :principals }
      t.string :claimed_severity                          # as reported; untrusted
      t.string :assessed_severity                         # ward's own call; drives posture
      t.string :confidence                                # verified | unverified
      t.boolean :exploited, null: false, default: false   # known exploited (a feed's evidence, or a person's word)
      t.string :actor                                     # actor threats: the handle
      t.string :target                                    # actor and anomaly threats: the named surface
      t.jsonb :affected, null: false, default: []         # [{ asset, name, host, component, version, verdict, exposure, ... }]
      t.string :status, null: false, default: "reported"
      t.jsonb :posture, null: false, default: []          # [{ tier, action, at, result, ref? }]
      t.jsonb :proposals, null: false, default: []        # [{ id, tier, action, title, detail, blast_radius, state, at, decided_at?, decided_by? }]
      t.jsonb :passes, null: false, default: []           # resolution checks that held: [{ at, evidence }]
      t.jsonb :resolution                                 # { criteria, evidence, resolved_at, verified_by }
      t.jsonb :upstream                                   # { source, repository, current?, fixed?, poll_hours, last_polled_at?, landed? }
      t.jsonb :enrichment                                 # what a CVE feed said, kept as evidence
      t.datetime :expires_at                              # actor threats: the end of the heightened-posture window
      t.integer :window_days                              # actor threats: how long a window runs (default 7)
      t.datetime :review_at                               # accepted risk: when it re-surfaces
      t.text :accepted_reason
      t.references :accepted_by, foreign_key: { to_table: :principals }
      t.string :todo_id                                   # the task Tier 1 opened
      t.string :schedule_id                               # the raised scan cadence Tier 0 set
      t.datetime :resolved_at
      t.timestamps
      t.index :status
      t.index :cve_ids, using: :gin
    end

    create_table :ward_threat_events, id: :string do |t|
      t.string :threat_id, null: false
      t.string :kind, null: false                         # reported | merged | triaged | transition | posture | note | indicator | ...
      t.string :from_status
      t.string :to_status
      t.references :principal, foreign_key: true          # who, when someone did it; null for ward itself
      t.text :body
      t.jsonb :data, null: false, default: {}
      t.datetime :created_at, null: false
      t.index [ :threat_id, :created_at ]
      t.foreign_key :ward_threats, column: :threat_id
    end

    create_table :ward_assets, id: :string do |t|
      t.string :ref, null: false                          # "coolify", "coolify:<uuid>", "server:<uuid>", "target:<address>", "manual:<name>"
      t.string :name, null: false
      t.string :kind, null: false                         # host | control_plane | application | service | database | target
      t.string :host
      t.string :role
      t.string :source, null: false                       # coolify | scan_target | person
      t.string :exposure                                  # public | tailnet | localhost
      t.string :image
      t.string :tag
      t.string :digest
      t.jsonb :components, null: false, default: {}       # what the inventory implies: { "php" => "8.3.30" | nil }
      t.jsonb :declared, null: false, default: {}         # what a person said: { components: [...], exposure: }
      t.jsonb :data, null: false, default: {}
      t.datetime :last_seen_at
      t.datetime :gone_at                                 # the source stopped reporting it
      t.timestamps
      t.index :ref, unique: true
      t.index :name
    end

    create_table :ward_observations, id: :string do |t|
      t.string :asset_id, null: false
      t.string :component, null: false
      t.string :version
      t.string :digest
      t.string :source, null: false                       # coolify | probe | person
      t.references :principal, foreign_key: true
      t.datetime :started_at                              # the process or container's start, when the prober knows it
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.jsonb :data, null: false, default: {}
      t.timestamps
      t.index [ :asset_id, :component, :last_seen_at ]
      t.foreign_key :ward_assets, column: :asset_id
    end
  end
end
