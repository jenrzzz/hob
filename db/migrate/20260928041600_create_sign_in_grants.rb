class CreateSignInGrants < ActiveRecord::Migration[8.1]
  def change
    create_table :sign_in_grants do |t|
      t.string :code_digest, null: false, index: { unique: true }
      t.references :principal, null: false, foreign_key: true
      t.string :code_challenge, null: false
      t.string :surface, null: false
      t.datetime :expires_at, null: false
      t.datetime :redeemed_at
      t.timestamps
    end
  end
end
