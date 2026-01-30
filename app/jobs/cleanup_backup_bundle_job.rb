# CleanupBackupBundleJob - Cleans up expired backup bundles
#
# This job runs periodically (via cron/scheduled task) to:
# 1. Find all migrations with expired backups (backup_expires_at < now)
# 2. Delete backup bundle files from disk
# 3. Delete downloaded data directories
# 4. Clear backup-related fields in migration records
#
# Storage Cleanup:
# - Deletes ZIP bundles from tmp/bundles/{token}/
# - Deletes downloaded data from tmp/migrations/{did}/
# - Frees up disk space after 24-hour retention period
#
# Scheduling:
# This job should be scheduled to run hourly via:
# - Sidekiq periodic job (sidekiq-scheduler gem)
# - Cron job calling: rails runner "CleanupBackupBundleJob.perform_now"
# - Or manually triggered as needed
#
# Database Updates:
# - Sets backup_bundle_path to nil
# - Sets downloaded_data_path to nil
# - Sets backup_expires_at to nil
#
# Usage:
#   CleanupBackupBundleJob.perform_later
#   CleanupBackupBundleJob.perform_now  # Synchronous (for cron)

class CleanupBackupBundleJob < ApplicationJob
  queue_as :low  # Low priority, runs in background

  def perform
    logger.info("[CleanupBackupBundleJob] Starting cleanup of expired backups")

    # Find all migrations with expired backups
    expired_migrations = Migration.with_expired_backups

    if expired_migrations.empty?
      logger.info("[CleanupBackupBundleJob] No expired backups found")
      return
    end

    logger.info("[CleanupBackupBundleJob] Found #{expired_migrations.count} expired backups to clean up")

    cleaned_count = 0
    failed_count = 0
    total_bytes_freed = 0

    expired_migrations.each do |migration|
      begin
        # Calculate size before deletion
        bundle_size = migration.backup_size || 0
        data_size = calculate_directory_size(migration.downloaded_data_path) if migration.downloaded_data_path.present?
        total_size = bundle_size + (data_size || 0)

        # Cleanup backup bundle
        migration.cleanup_backup! if migration.backup_bundle_path.present?

        # Cleanup downloaded data
        migration.cleanup_downloaded_data! if migration.downloaded_data_path.present?

        total_bytes_freed += total_size
        cleaned_count += 1

        logger.info("[CleanupBackupBundleJob] Cleaned up migration #{migration.token}: freed #{format_bytes(total_size)}")

      rescue StandardError => e
        failed_count += 1
        logger.error("[CleanupBackupBundleJob] Failed to cleanup migration #{migration.token}: #{e.message}")
        logger.error(e.backtrace.join("\n"))
      end
    end

    logger.info("[CleanupBackupBundleJob] Cleanup complete: #{cleaned_count} cleaned, #{failed_count} failed, #{format_bytes(total_bytes_freed)} freed")

  rescue StandardError => e
    logger.error("[CleanupBackupBundleJob] Unexpected error: #{e.message}")
    logger.error(e.backtrace.join("\n"))
    raise
  end

  private

  # Calculate total size of a directory
  def calculate_directory_size(path)
    return 0 unless path.present? && Dir.exist?(path)

    total_size = 0
    Dir.glob(File.join(path, '**', '*')).each do |file|
      total_size += File.size(file) if File.file?(file)
    end

    total_size
  end

  # Format bytes for human-readable output
  def format_bytes(bytes)
    return "0 B" if bytes.zero?

    units = ['B', 'KB', 'MB', 'GB', 'TB']
    exp = (Math.log(bytes) / Math.log(1024)).to_i
    exp = [exp, units.length - 1].min

    value = bytes.to_f / (1024 ** exp)
    "#{value.round(2)} #{units[exp]}"
  end
end
