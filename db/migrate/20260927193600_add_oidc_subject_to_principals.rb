class AddOidcSubjectToPrincipals < ActiveRecord::Migration[8.1]
  def change
    add_column :principals, :oidc_subject, :string
    add_index :principals, :oidc_subject, unique: true
  end
end
