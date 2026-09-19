# Phones running the companion app (clients/ios): where a person is pinged
# when the sentinel needs one. One row per APNs device token; the app
# re-registers at every launch, so a rotated token is an upsert and a dead
# one is deleted when Apple says so. Not realm-scoped: a device belongs to a
# person, not to a conversation.
class CreateDevices < ActiveRecord::Migration[8.1]
  def change
    create_table :devices do |t|
      t.references :principal, null: false, foreign_key: true # the person the phone belongs to
      t.string :platform, null: false, default: "ios"
      t.string :token, null: false                # the APNs device token, hex
      t.string :environment, null: false          # sandbox | production: which APNs host the token answers on
      t.string :name                              # "Jenner's iPhone"
      t.string :app_version
      t.datetime :last_seen_at                    # last registration
      t.datetime :last_pushed_at                  # last delivery Apple accepted
      t.timestamps
      t.index :token, unique: true
    end
  end
end
