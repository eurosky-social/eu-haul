# DeleteMigrationJob - Deletes completed migration records for GDPR compliance
#
# This job is scheduled by ActivateAccountJob after successful migration completion.
# It provides a short grace period (10 minutes) for users to:
# - View the completion status page
# - Copy their rotation key
# - Download their backup bundle (if created)
# - Receive and read the completion email
#
# After the grace period, the migration record is permanently deleted because:
# 1. GDPR compliance - no legitimate reason to store personal data
# 2. Security - minimize attack surface (encrypted credentials already cleared)
# 3. User has been emailed all critical information
# 4. Backup bundle (if created) has limited usefulness after migration
#
# What gets deleted:
# - Migration database record (email, DID, handles, token)
# - Backup bundle file (if exists)
# - Downloaded data directory (if exists)
#
# What the user should have saved:
# - Rotation key (from completion page or email)
# - Backup bundle (downloaded within 10-minute window)
# - Migration summary (from email)
#
# Queue: :low (no urgency, cleanup task)
# Retries: None (if it fails, cleanup job will catch it later)

class DeleteMigrationJob < ApplicationJob
  queue_as :low

  def perform(migration_id)
    migration = Migration.find_by(id: migration_id)

    unless migration
      Rails.logger.warn("Migration #{migration_id} not found for deletion (may have been deleted already)")
      return
    end

    # Only delete completed migrations
    # Failed migrations should be handled by CleanupOldMigrationsJob instead
    unless migration.completed?
      Rails.logger.warn("Migration #{migration.token} is not completed (status: #{migration.status}), skipping deletion")
      return
    end

    Rails.logger.info("Deleting completed migration #{migration.token} for GDPR compliance")

    # Clean up associated files first
    cleanup_migration_files(migration)

    # Delete the migration record
    token = migration.token
    did = migration.did
    migration.destroy!

    Rails.logger.info("Successfully deleted migration #{token} (DID: #{did})")
    Rails.logger.info("User personal data removed from system")

  rescue StandardError => e
    Rails.logger.error("Failed to delete migration #{migration_id}: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    # Don't re-raise - let CleanupOldMigrationsJob handle it later
  end

  private

  def cleanup_migration_files(migration)
    # Clean up backup bundle if it exists
    if migration.backup_bundle_path.present?
      begin
        migration.cleanup_backup!
        Rails.logger.info("Backup bundle cleaned up for migration #{migration.token}")
      rescue StandardError => e
        Rails.logger.warn("Failed to cleanup backup for migration #{migration.token}: #{e.message}")
      end
    end

    # Clean up downloaded data if it exists
    if migration.downloaded_data_path.present?
      begin
        migration.cleanup_downloaded_data!
        Rails.logger.info("Downloaded data cleaned up for migration #{migration.token}")
      rescue StandardError => e
        Rails.logger.warn("Failed to cleanup downloaded data for migration #{migration.token}: #{e.message}")
      end
    end
  end
end
