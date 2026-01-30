class AddBackupBundleFieldsToMigrations < ActiveRecord::Migration[7.1]
  def change
    add_column :migrations, :create_backup_bundle, :boolean, default: true, null: false
    add_column :migrations, :downloaded_data_path, :string
    add_column :migrations, :backup_bundle_path, :string
    add_column :migrations, :backup_created_at, :datetime
    add_column :migrations, :backup_expires_at, :datetime
    add_column :migrations, :rotation_private_key_ciphertext, :text

    # Index for finding expired backups to clean up
    add_index :migrations, :backup_expires_at
  end
end
