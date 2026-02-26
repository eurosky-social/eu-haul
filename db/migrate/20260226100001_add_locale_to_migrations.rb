class AddLocaleToMigrations < ActiveRecord::Migration[7.1]
  def change
    add_column :migrations, :locale, :string, default: 'en', null: false
  end
end
