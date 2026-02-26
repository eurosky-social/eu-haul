class AddTargetPdsContactEmailToMigrations < ActiveRecord::Migration[7.1]
  def change
    add_column :migrations, :target_pds_contact_email, :string
  end
end
