# The admin sentinel history pages newest first by (created_at, id) through
# every request ever asked; without this each page sorts the whole table.
class IndexSentinelRequestsOnCreatedAtAndId < ActiveRecord::Migration[8.1]
  def change
    add_index :sentinel_requests, %i[created_at id]
    add_index :petitions, %i[created_at id]
  end
end
