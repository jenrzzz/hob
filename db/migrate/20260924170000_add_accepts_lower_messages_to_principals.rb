# hob.agent.message refuses a recipient cleared above the capability's tier.
# This flag lets a person open one agent's inbox to that tier anyway: its
# owner has decided the lower-tier agents may write to it (hob:inbox).
class AddAcceptsLowerMessagesToPrincipals < ActiveRecord::Migration[8.1]
  def change
    add_column :principals, :accepts_lower_messages, :boolean, null: false, default: false
  end
end
