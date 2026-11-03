# PLUGINS.md, Phase 1c (section 6): an installation's namespace is not its
# plugin type. A manifest names its operations under its type
# ("contacts.card.get"), and hob offers each under the installation's
# namespace ("contacts-house.card.get"). remote_name keeps the plugin's own
# name, which is how a delivery addresses it (POST /hob/capabilities/<it>),
# so the household's naming never dictates the plugin's routes.
#
# Every installation so far has its type as its namespace (mise), so the
# names already match.
class AddRemoteNameToCapabilities < ActiveRecord::Migration[8.1]
  def up
    add_column :capabilities, :remote_name, :string
    execute "UPDATE capabilities SET remote_name = name WHERE plugin_id IS NOT NULL"
    add_index :capabilities, [ :plugin_id, :remote_name ], unique: true, where: "plugin_id IS NOT NULL"
  end

  def down
    remove_index :capabilities, [ :plugin_id, :remote_name ]
    remove_column :capabilities, :remote_name
  end
end
