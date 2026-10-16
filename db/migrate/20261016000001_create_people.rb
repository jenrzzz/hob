# Who the household knows (PEOPLE.md).
#
# people            a person: names, key dates, whose relationship it mostly
#                   is, and how often the household expects to hear from them
# person_handles    the addresses that reach a person: one handle, one person
# people_groups     a circle, or a group chat: something a person is in
# group_memberships who is in which group
# people_events     the append-only log: what passed between the household
#                   and a person (or a group), and where hob saw it
# people_loops      what is still open: derived from events by People::Loops,
#                   never written any other way; a person's snooze or
#                   dismissal is the only state kept beside it
# people_notes      what agents and people wrote about a person, with a byline
# people_cursors    where People::Sync is in each text backend's stream
#
# Every table is realm-scoped. A handle's realm and a membership's are their
# person's, copied so RLS needs no join. An event's realm is the higher of
# its source's and its person's, and a loop's is its opening event's: a
# household agent can know Eugene exists and not see Jenner's 1:1 with him.
class CreatePeople < ActiveRecord::Migration[8.1]
  TABLES = %w[people person_handles people_groups group_memberships people_events people_loops people_notes people_cursors].freeze

  def up
    create_table :people, id: :string do |t|
      t.string :display_name, null: false
      t.string :names, array: true, null: false, default: [] # aliases: what else people call them
      t.jsonb :key_dates, null: false, default: []           # [{ kind, date: "YYYY-MM-DD" | "--MM-DD", recurs }]
      t.boolean :automated, null: false, default: false      # a service, not a person: never opens a loop
      t.integer :cadence_days                                # how often a person said to expect contact
      t.string :realm, null: false
      t.references :principal, foreign_key: true             # whose relationship this mostly is; null: the household's
      t.references :created_by, foreign_key: { to_table: :principals }
      t.string :merged_into_id                               # merged away: this record now answers as that one
      t.timestamps
      t.index :merged_into_id
      t.index :names, using: :gin
    end

    create_table :person_handles, id: :string do |t|
      t.references :person, null: false, type: :string, foreign_key: true
      t.string :kind, null: false                            # phone, email, other
      t.string :address, null: false                         # normalized: +15551234567, ana@example.com
      t.string :label
      t.boolean :opens_loops, null: false, default: true     # false once a person dismissed a loop "never again"
      t.string :realm, null: false
      t.timestamps
      t.index [ :kind, :address ], unique: true              # one handle, one person: a merge is how two become one
    end

    create_table :people_groups, id: :string do |t|
      t.string :name, null: false
      t.string :chat_ref                                     # text:<chat id>, for a group chat
      t.string :realm, null: false
      t.references :principal, foreign_key: true
      t.timestamps
      t.index :chat_ref, unique: true, where: "chat_ref IS NOT NULL"
      t.index [ :realm, :name ]
    end

    create_table :group_memberships, id: :string do |t|
      t.references :group, null: false, type: :string, foreign_key: { to_table: :people_groups }, index: false
      t.references :person, null: false, type: :string, foreign_key: true
      t.string :realm, null: false
      t.timestamps
      t.index [ :group_id, :person_id ], unique: true
    end

    create_table :people_events, id: :string do |t|
      t.references :person, type: :string, foreign_key: true, index: false
      t.references :group, type: :string, foreign_key: { to_table: :people_groups }, index: false
      t.datetime :at, null: false
      t.string :kind, null: false
      t.string :direction                                    # inbound, outbound, mutual; none for a note or a dismissal
      t.string :channel                                      # text, email, call, in_person, other
      t.text :summary
      t.string :source_kind, null: false                     # text, mail, calendar, dictated, agent
      t.string :source_ref                                   # the message's id, not a copy of it
      t.references :principal, foreign_key: true             # whose side of the relationship
      t.references :recorded_by, null: false, foreign_key: { to_table: :principals }
      t.string :surface
      t.string :sentinel_request_id
      t.string :supersedes_id                                # a correction names what it corrects
      t.string :realm, null: false
      t.datetime :created_at, null: false
      t.index [ :person_id, :at ]
      t.index [ :group_id, :at ]
      t.index [ :source_kind, :source_ref ], unique: true, where: "source_ref IS NOT NULL AND source_kind IN ('text', 'mail', 'calendar')"
    end

    create_table :people_loops, id: :string do |t|
      t.references :person, type: :string, foreign_key: true, index: false
      t.references :group, type: :string, foreign_key: { to_table: :people_groups }, index: false
      t.references :principal, foreign_key: true
      t.string :kind, null: false
      t.string :channel                                      # what answers it, for unanswered_inbound
      t.string :handle_id                                    # the handle it came in on, when derived
      t.string :opened_by_id, null: false                    # the first event of the silence
      t.string :latest_event_id, null: false                 # the most recent event that kept it open
      t.datetime :opened_at, null: false
      t.text :summary
      t.string :state, null: false, default: "open"          # open, closed, dismissed
      t.string :closed_by_id                                 # the event that closed or dismissed it
      t.datetime :closed_at
      t.datetime :snoozed_until
      t.string :realm, null: false
      t.timestamps
      t.index [ :person_id, :state ]
      t.index [ :state, :opened_at ]
    end
    add_foreign_key :people_loops, :people_events, column: :opened_by_id
    add_foreign_key :people_loops, :people_events, column: :latest_event_id
    add_foreign_key :people_loops, :people_events, column: :closed_by_id

    create_table :people_notes, id: :string do |t|
      t.references :person, type: :string, foreign_key: true, index: false
      t.references :group, type: :string, foreign_key: { to_table: :people_groups }, index: false
      t.text :body, null: false
      t.references :author, null: false, foreign_key: { to_table: :principals }
      t.string :surface
      t.string :sentinel_request_id
      t.string :realm, null: false
      t.datetime :created_at, null: false
      t.index [ :person_id, :created_at ]
      t.index [ :group_id, :created_at ]
    end

    create_table :people_cursors, id: :string do |t|
      t.string :source, null: false                          # text:<backend name>
      t.text :cursor
      t.datetime :synced_at
      t.text :last_error
      t.string :realm, null: false
      t.timestamps
      t.index :source, unique: true
    end

    TABLES.each do |table|
      execute <<~SQL
        ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY;
        ALTER TABLE #{table} FORCE ROW LEVEL SECURITY;
        CREATE POLICY realm_visibility ON #{table}
          USING ((SELECT rank FROM realms WHERE slug = #{table}.realm) <= app_clearance_rank());
      SQL
    end
  end

  def down
    TABLES.reverse_each do |table|
      execute "DROP POLICY IF EXISTS realm_visibility ON #{table}"
      drop_table table
    end
  end
end
