class RemoveDidUniqueIndexFromMigrations < ActiveRecord::Migration[7.1]
  def up
    # Remove the unique index on DID to allow multiple migrations per account
    # This enables:
    # 1. Future migrations of the same account to different PDS
    # 2. Retry migrations after old ones are cleaned up
    # 3. Historical tracking of migrations
    #
    # The application layer now enforces that only one ACTIVE migration
    # per DID can exist at a time (via model validation)
    remove_index :migrations, :did, if_exists: true

    # Add a non-unique index for query performance
    add_index :migrations, :did, unique: false
  end

  def down
    # Restore unique index (will fail if duplicates exist)
    remove_index :migrations, :did, if_exists: true
    add_index :migrations, :did, unique: true
  end
end
