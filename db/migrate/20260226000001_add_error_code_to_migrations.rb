class AddErrorCodeToMigrations < ActiveRecord::Migration[7.1]
  def change
    add_column :migrations, :error_code, :string
    add_index :migrations, :error_code
  end
end
