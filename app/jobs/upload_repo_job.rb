# UploadRepoJob - Uploads repository from local file to new PDS
#
# This job uploads the repository CAR file that was previously downloaded
# by DownloadAllDataJob. It's used when backup is enabled to avoid
# re-downloading the repository.
#
# Flow:
# 1. Verify local repo file exists
# 2. Login to new PDS
# 3. Upload repo CAR file using importRepo API
# 4. Verify upload success
# 5. Advance to pending_blobs status
#
# Differences from ImportRepoJob:
# - ImportRepoJob: Downloads from old PDS and streams to new PDS
# - UploadRepoJob: Uploads from local file to new PDS
#
# Error Handling:
# - Missing file: fail with error
# - Upload failure: retry with exponential backoff
# - Authentication failure: fail immediately
# - Overall failure: mark migration as failed
#
# Usage:
#   UploadRepoJob.perform_later(migration.id)

class UploadRepoJob < ApplicationJob
  queue_as :migrations

  # Retry configuration
  retry_on StandardError, wait: :exponentially_longer, attempts: 3
  retry_on GoatService::RateLimitError, wait: :polynomially_longer, attempts: 5

  def perform(migration_id)
    migration = Migration.find(migration_id)
    logger.info("Starting repo upload for migration #{migration.token} (DID: #{migration.did})")

    # Step 1: Verify local file exists
    unless migration.downloaded_data_path.present?
      raise "Downloaded data path not set"
    end

    data_dir = Pathname.new(migration.downloaded_data_path)
    repo_path = data_dir.join('repo.car')

    unless File.exist?(repo_path)
      raise "Repository file not found at: #{repo_path}"
    end

    logger.info("Found local repository file: #{repo_path} (#{format_bytes(File.size(repo_path))})")

    # Step 2: Initialize GoatService and login
    goat = GoatService.new(migration)
    goat.login_new_pds

    # Step 3: Upload repository
    logger.info("Uploading repository to new PDS...")
    goat.import_repo(repo_path.to_s)

    logger.info("Repository upload completed")

    # Step 4: Advance to next stage
    migration.advance_to_pending_blobs!

  rescue StandardError => e
    logger.error("Repo upload failed for migration #{migration.id}: #{e.message}")
    logger.error(e.backtrace.join("\n"))

    migration.reload
    migration.mark_failed!("Repo upload failed: #{e.message}")

    raise
  end

  private

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
