# CleanupOldMigrationsJob - Automatically delete old migration records
#
# This job enforces data retention policies for GDPR compliance and security:
# - Completed migrations: deleted after 24 hours (users have time to verify success)
# - Failed migrations: deleted after 7 days (allows retry window)
# - Also cleans up any associated backup files
#
# Rationale for deletion:
# 1. GDPR compliance: Minimize storage of personal data (email, DID, credentials)
# 2. Security: Reduce attack surface (fewer encrypted credentials stored)
# 3. DID reusability: Allows users to migrate same account again in the future
# 4. Storage efficiency: Prevents database bloat
#
# Schedule: Run daily via cron or Sidekiq periodic job
class CleanupOldMigrationsJob < ApplicationJob
  queue_as :low

  # Retention periods
  # Note: Completed migrations are normally deleted by DeleteMigrationJob (2-day grace period)
  # or earlier if the user clicks "Delete my data" on the status page.
  # This cleanup job is a safety net for any completed migrations that weren't caught by DeleteMigrationJob
  COMPLETED_RETENTION = 2.days  # Safety net - most are deleted via DeleteMigrationJob or user action
  FAILED_RETENTION = 7.days     # Give users time to retry failed migrations

  def perform
    deleted_completed = cleanup_completed_migrations
    deleted_failed = cleanup_failed_migrations

    Rails.logger.info(
      "Cleanup completed: #{deleted_completed} completed migrations, " \
      "#{deleted_failed} failed migrations deleted"
    )
  end

  private

  def cleanup_completed_migrations
    cutoff_time = COMPLETED_RETENTION.ago

    migrations = Migration.where(status: :completed)
                          .where('updated_at < ?', cutoff_time)

    count = 0
    migrations.find_each do |migration|
      cleanup_migration_files(migration)
      migration.destroy!
      count += 1
    rescue StandardError => e
      Rails.logger.error(
        "Failed to delete completed migration #{migration.token}: #{e.message}"
      )
    end

    count
  end

  def cleanup_failed_migrations
    cutoff_time = FAILED_RETENTION.ago

    migrations = Migration.where(status: :failed)
                          .where('updated_at < ?', cutoff_time)

    count = 0
    migrations.find_each do |migration|
      cleanup_migration_files(migration)
      migration.destroy!
      count += 1
    rescue StandardError => e
      Rails.logger.error(
        "Failed to delete failed migration #{migration.token}: #{e.message}"
      )
    end

    count
  end

  def cleanup_migration_files(migration)
    # Clean up backup bundle if it exists
    migration.cleanup_backup! if migration.backup_bundle_path.present?

    # Clean up downloaded data if it exists
    migration.cleanup_downloaded_data! if migration.downloaded_data_path.present?
  rescue StandardError => e
    Rails.logger.warn(
      "Failed to cleanup files for migration #{migration.token}: #{e.message}"
    )
    # Continue with deletion even if file cleanup fails
  end
end
