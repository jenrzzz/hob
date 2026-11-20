# Searchable collections (MELUZINA.md, "Searchable collections"): a
# collection may name the field of its documents to embed, and records keep
# a vector beside their data, compared only within one model like
# observations. A persona may name collections as her own corpus tools.
class AddSearchToRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :record_collections, :embed_path, :string
    add_column :records, :embedding, :vector
    add_column :records, :embedding_model, :string
    add_index :records, :collection_id, where: "embedding IS NULL AND retracted_at IS NULL", name: "index_records_unembedded"
    # { corpora: [{ tool, collection, description }] }
    add_column :personas, :tools, :jsonb, null: false, default: {}
  end
end
