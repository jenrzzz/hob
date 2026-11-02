# PLUGINS.md, Phase 1b (section 4): an installation's own key, which signs
# what it tells hob (its manifest, its announcements), and what hob has
# accepted from it so far.
#
#   key, previous_key   the key hob minted for it (HOB_PLUGIN_KEY), and the
#                       one before it, still accepted until a manifest signed
#                       with the new one arrives (key_confirmed_at)
#   signed_since        when a signed manifest first verified: from then on an
#                       unsigned answer is refused, and only from then on may
#                       it refresh itself (announce)
#   manifest_revision   the plugin's revision and the digest of its body, as
#   manifest_digest     last reconciled: an older revision, or the same one
#                       with another body, is refused
class AddSigningToPlugins < ActiveRecord::Migration[8.1]
  def change
    change_table :plugins, bulk: true do |t|
      t.string :key
      t.string :previous_key
      t.datetime :key_confirmed_at
      t.datetime :signed_since
      t.bigint :manifest_revision
      t.string :manifest_digest
      t.datetime :refreshed_at
      t.datetime :announced_at
    end
  end
end
