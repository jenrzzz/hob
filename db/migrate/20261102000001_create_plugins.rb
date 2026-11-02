# PLUGINS.md, Phase 1 (sections 4 and 6): a plugin installation is a thing
# of its own, not a free-text `config.surface` on each capability row. Each
# has a `surface` principal (what a quarantine freezes, and what will hold
# its keys), an immutable namespace its capabilities' names start with, the
# plugin type its manifest names, where it is, and optionally the person it
# belongs to. Every surface already registered becomes an installation of
# the same name, with no owner: a household one, as it is today.
class CreatePlugins < ActiveRecord::Migration[8.1]
  def up
    create_table :plugins do |t|
      t.string :namespace, null: false, index: { unique: true }
      t.string :plugin_type, null: false
      t.references :principal, null: false, foreign_key: true, index: { unique: true }
      t.references :owner, foreign_key: { to_table: :principals }
      t.string :base_url, null: false
      t.timestamps
    end
    add_reference :capabilities, :plugin, foreign_key: true

    surfaces = select_values(<<~SQL)
      SELECT DISTINCT config->>'surface' FROM capabilities
       WHERE venue = 'webhook' AND config->>'surface' IS NOT NULL
    SQL
    surfaces.each do |surface|
      name = "plugin:#{surface}"
      raise "a principal named #{name} already exists" if select_value("SELECT 1 FROM principals WHERE name = #{quote(name)}")

      url = select_value("SELECT config->>'url' FROM capabilities WHERE venue = 'webhook' AND config->>'surface' = #{quote(surface)} LIMIT 1")
      base = url.to_s.sub(%r{/hob/capabilities/[^/]+\z}, "")
      principal_id = select_value(<<~SQL)
        INSERT INTO principals (kind, name, max_clearance, created_at, updated_at)
        VALUES ('surface', #{quote(name)}, 'household', now(), now()) RETURNING id
      SQL
      plugin_id = select_value(<<~SQL)
        INSERT INTO plugins (namespace, plugin_type, principal_id, base_url, created_at, updated_at)
        VALUES (#{quote(surface)}, #{quote(surface)}, #{principal_id}, #{quote(base)}, now(), now()) RETURNING id
      SQL
      execute "UPDATE capabilities SET plugin_id = #{plugin_id} WHERE venue = 'webhook' AND config->>'surface' = #{quote(surface)}"
    end
  end

  def down
    remove_reference :capabilities, :plugin
    principal_ids = select_values("SELECT principal_id FROM plugins")
    drop_table :plugins
    execute "DELETE FROM principals WHERE id IN (#{principal_ids.join(',')})" if principal_ids.any?
  end
end
