# The lowest realm an agent may be heard in on hob's IRC (IRC.md, "The
# floor"): a persona that lives upstairs keeps to channels and DMs at or
# above it. Null is no floor.
class AddIrcFloorToPrincipals < ActiveRecord::Migration[8.1]
  def change
    add_column :principals, :irc_floor, :string
  end
end
