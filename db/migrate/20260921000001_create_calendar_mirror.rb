# hob's household calendar mirror (SENTINEL.md, hob.calendar.push): the
# ingest half of the calendar bouncer. calendar_events is what an agent has
# pushed, keyed by (source_agent, owner, calendar, uid); title and location
# only ever land there when the push said visibility "details".
# calendar_contributors is the small owner -> allowed-agents registry the
# handler checks before it writes anything: a person adds a row, an agent
# earns nothing on its own. Neither is realm-scoped, like agent_messages:
# the capability's realm is fixed at household, not a per-row choice.
class CreateCalendarMirror < ActiveRecord::Migration[8.1]
  def change
    create_table :calendar_contributors do |t|
      t.references :owner, null: false, foreign_key: { to_table: :principals } # a household member
      t.references :agent, null: false, foreign_key: { to_table: :principals } # allowed to push for them
      t.timestamps
      t.index [ :owner_id, :agent_id ], unique: true
    end

    create_table :calendar_events, id: :string do |t|
      t.references :source_agent, null: false, foreign_key: { to_table: :principals } # who pushed it
      t.references :owner, null: false, foreign_key: { to_table: :principals }         # whose calendar
      t.string :calendar, null: false, default: "" # free-form label: "work", "family"
      t.string :uid, null: false
      t.datetime :start_at, null: false
      t.datetime :end_at, null: false
      t.boolean :all_day, null: false, default: false
      t.boolean :busy, null: false, default: true
      t.string :status  # confirmed | tentative | cancelled
      t.string :title    # only stored when the push's visibility was "details"
      t.string :location # only stored when the push's visibility was "details"
      t.string :visibility, null: false, default: "free_busy"
      t.timestamps
      t.index [ :source_agent_id, :owner_id, :calendar, :uid ], unique: true, name: "index_calendar_events_on_agent_owner_calendar_uid"
    end
  end
end
