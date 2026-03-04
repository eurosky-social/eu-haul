class CreateLegalConsents < ActiveRecord::Migration[7.1]
  def change
    create_table :legal_consents do |t|
      t.string :did, null: false
      t.string :migration_token
      t.references :tos_snapshot, null: false, foreign_key: { to_table: :legal_snapshots }
      t.references :privacy_policy_snapshot, null: false, foreign_key: { to_table: :legal_snapshots }
      t.text :ip_address_ciphertext
      t.datetime :accepted_at, null: false
      t.timestamps
    end

    add_index :legal_consents, :did
    add_index :legal_consents, :migration_token
  end
end
