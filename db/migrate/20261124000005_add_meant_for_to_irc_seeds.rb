# A seed may be meant for one agent (IRC.md, "The pulse"): something mined
# from that persona's own threads, shown in the tray only to her. One meant
# for nobody is anyone's, as before.
class AddMeantForToIrcSeeds < ActiveRecord::Migration[8.1]
  def change
    add_reference :irc_seeds, :meant_for, null: true, foreign_key: { to_table: :principals }
  end
end
