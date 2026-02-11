class AddOldPdsTokensToMigrations < ActiveRecord::Migration[7.1]
  def change
    add_column :migrations, :encrypted_old_access_token, :text
    add_column :migrations, :encrypted_old_refresh_token, :text
  end
end
