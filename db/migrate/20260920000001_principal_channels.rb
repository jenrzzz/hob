# Each principal may have its own channel: an ntfy topic (or anything Notify
# can post to) that hears about its missions. Two agents on one household
# should not share a topic, or each wakes for the other's work.
class PrincipalChannels < ActiveRecord::Migration[8.1]
  def change
    add_column :principals, :channel, :string
  end
end
