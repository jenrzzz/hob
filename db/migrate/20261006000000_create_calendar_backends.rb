# Calendars (CALENDARS.md): hob owns an abstract, read-only calendar
# contract (calendars, events); where a calendar actually lives is a
# backend, and a backend is a row. The first kinds are `ics` (a
# subscription URL) and `fastmail` (CalDAV). The events themselves are
# never stored here.
#
# calendar_backends  one place calendars are kept: whose they are, the
#                    realm of everything in them, and how to reach them
#
# Realm-scoped like todo_backends and budget_backends: a backend above the
# request's clearance does not exist as far as that request can tell, and
# neither does an event in it. Unrelated to calendar_events, the mirror
# agents push into (hob.calendar.push).
class CreateCalendarBackends < ActiveRecord::Migration[8.1]
  def up
    create_table :calendar_backends, id: :string do |t|
      t.string :name, null: false, index: { unique: true } # "family-fastmail": the prefix of every id
      t.string :kind, null: false                 # ics | fastmail | caldav (an adapter under Calendars::Backends)
      t.references :principal, null: false, foreign_key: true # whose calendars these are: a person
      t.string :realm, null: false                # of everything in it
      t.jsonb :config, null: false, default: {}   # ics: url | url_env; fastmail: username, key | key_env, calendars
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE calendar_backends ENABLE ROW LEVEL SECURITY;
      ALTER TABLE calendar_backends FORCE ROW LEVEL SECURITY;
      CREATE POLICY realm_visibility ON calendar_backends
        USING ((SELECT rank FROM realms WHERE slug = calendar_backends.realm) <= app_clearance_rank());
    SQL
  end

  def down
    execute "DROP POLICY IF EXISTS realm_visibility ON calendar_backends"
    drop_table :calendar_backends
  end
end
