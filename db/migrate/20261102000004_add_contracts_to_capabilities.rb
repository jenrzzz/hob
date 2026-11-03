# PLUGINS.md, Phase 1d (section 7): a capability's contract, and what happens
# when a plugin changes it under the same name.
#
#   contract_revision   bumped whenever its input schema changes; a request
#                       records the revision it was asked (and approved)
#                       against, and is not delivered under another
#   suspended_at,       set when a refresh refuses an entry: a breaking
#   suspended_reason    schema change, or a changed declaration of kind or
#                       realm. The row keeps the contract a person accepted;
#                       nothing reaches it until a person resumes it, after
#                       hob has read a compatible one from the plugin again
#   deprecated_at,      what the manifest says about the entry's retirement,
#   sunset_at           shown to a caller before it is gone
class AddContractsToCapabilities < ActiveRecord::Migration[8.1]
  def change
    change_table :capabilities, bulk: true do |t|
      t.integer :contract_revision, null: false, default: 1
      t.datetime :suspended_at
      t.text :suspended_reason
      t.datetime :deprecated_at
      t.datetime :sunset_at
    end
    add_column :sentinel_requests, :contract_revision, :integer
  end
end
