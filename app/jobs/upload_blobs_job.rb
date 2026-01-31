# UploadBlobsJob - Uploads blobs from local files to new PDS
#
# This job uploads all blob files that were previously downloaded
# by DownloadAllDataJob. It's used when backup is enabled to avoid
# re-downloading the blobs.
#
# Flow:
# 1. Verify local blobs directory exists
# 2. Login to new PDS
# 3. List all local blob files
# 4. Upload blobs in parallel batches (10 at a time)
# 5. Track progress and update after each batch
# 6. Advance to pending_prefs status
#
# Differences from ImportBlobsJob:
# - ImportBlobsJob: Downloads from old PDS and streams to new PDS
# - UploadBlobsJob: Uploads from local files to new PDS
#
# Memory Optimization:
# - Parallel uploads (10 concurrent)
# - Progress tracking every batch
# - GC after each batch
# - Immediate file cleanup after upload (optional)
#
# Error Handling:
# - Missing files: fail with error
# - Upload failure: retry individual blobs
# - Rate limits: longer backoff
# - Overall failure: mark migration as failed
#
# Usage:
#   UploadBlobsJob.perform_later(migration.id)

class UploadBlobsJob < ApplicationJob
  queue_as :migrations

  # Constants
  PARALLEL_UPLOADS = 10
  MAX_RETRIES = 3

  # Retry configuration
  retry_on StandardError, wait: :exponentially_longer, attempts: 3
  retry_on GoatService::RateLimitError, wait: :polynomially_longer, attempts: 5

  def perform(migration_id)
    migration = Migration.find(migration_id)
    logger.info("Starting blob upload for migration #{migration.token} (DID: #{migration.did})")

    # Step 1: Verify local blobs directory exists
    unless migration.downloaded_data_path.present?
      raise "Downloaded data path not set"
    end

    data_dir = Pathname.new(migration.downloaded_data_path)
    blobs_dir = data_dir.join('blobs')

    unless Dir.exist?(blobs_dir)
      raise "Blobs directory not found at: #{blobs_dir}"
    end

    # Step 2: List all local blob files
    blob_files = Dir.glob(blobs_dir.join('*')).select { |f| File.file?(f) }
    logger.info("Found #{blob_files.length} blobs to upload")

    # Step 3: Initialize GoatService and login
    goat = GoatService.new(migration)
    goat.login_new_pds

    # Step 4: Upload all blobs in parallel
    upload_all_blobs(migration, goat, blob_files)

    logger.info("Blob upload completed")

    # Step 5: Advance to next stage
    migration.advance_to_pending_prefs!

  rescue StandardError => e
    logger.error("Blob upload failed for migration #{migration&.id || migration_id}: #{e.message}")
    logger.error(e.backtrace.join("\n"))

    if migration
      migration.reload
      migration.mark_failed!("Blob upload failed: #{e.message}")
    end

    raise
  end

  private

  # Upload all blobs in parallel batches
  def upload_all_blobs(migration, goat, blob_files)
    total_blobs = blob_files.length
    uploaded_count = 0
    failed_cids = []
    total_bytes = 0

    # Thread-safe counters
    mutex = Mutex.new

    # Process blobs in parallel batches
    blob_files.each_slice(PARALLEL_UPLOADS).with_index do |batch, batch_index|
      threads = batch.map.with_index do |blob_file, batch_offset|
        Thread.new do
          begin
            index = batch_index * PARALLEL_UPLOADS + batch_offset
            cid = File.basename(blob_file)

            # Get file size
            blob_size = File.size(blob_file)

            # Upload blob to new PDS
            upload_blob_with_retry(goat, blob_file)

            # Update metrics (thread-safe)
            mutex.synchronize do
              uploaded_count += 1
              total_bytes += blob_size
            end

            logger.info("Uploaded blob #{index + 1}/#{total_blobs}: #{cid} (#{format_bytes(blob_size)})")

          rescue StandardError => e
            logger.error("Failed to upload blob #{cid}: #{e.message}")
            mutex.synchronize do
              failed_cids << cid
            end
          end
        end
      end

      # Wait for all threads in this batch to complete
      threads.each(&:join)

      # Update progress after each batch
      update_upload_progress(migration, uploaded_count, total_blobs, total_bytes)

      # Run garbage collection after each batch
      logger.debug("Running garbage collection after batch #{batch_index + 1}")
      GC.start
    end

    # Log summary
    logger.info("Upload complete: #{uploaded_count}/#{total_blobs} successful")
    logger.info("Total data uploaded: #{format_bytes(total_bytes)}")

    if failed_cids.any?
      logger.warn("Failed to upload #{failed_cids.length} blobs: #{failed_cids.join(', ')}")
      migration.progress_data ||= {}
      migration.progress_data['failed_uploads'] = failed_cids
      migration.save!
    end

    # Final GC
    GC.start
  end

  # Upload blob with retry logic
  def upload_blob_with_retry(goat, blob_file, attempt = 1)
    goat.upload_blob(blob_file)
  rescue GoatService::RateLimitError => e
    if attempt < MAX_RETRIES
      backoff = 2 ** (attempt + 2) # 8s, 16s, 32s
      logger.warn("Rate limit hit uploading blob (attempt #{attempt}/#{MAX_RETRIES}): #{blob_file} - retrying in #{backoff}s")
      sleep(backoff)
      upload_blob_with_retry(goat, blob_file, attempt + 1)
    else
      logger.error("Blob upload failed after #{MAX_RETRIES} rate-limit retries: #{blob_file}")
      raise
    end
  rescue GoatService::NetworkError, GoatService::TimeoutError => e
    if attempt < MAX_RETRIES
      logger.warn("Blob upload failed (attempt #{attempt}/#{MAX_RETRIES}): #{blob_file} - #{e.message}")
      sleep(2 ** attempt) # 2s, 4s, 8s
      upload_blob_with_retry(goat, blob_file, attempt + 1)
    else
      logger.error("Blob upload failed after #{MAX_RETRIES} attempts: #{blob_file}")
      raise
    end
  end

  # Update upload progress in database
  def update_upload_progress(migration, uploaded, total, bytes_uploaded)
    migration.progress_data ||= {}
    migration.progress_data['blobs_uploaded'] = uploaded
    migration.progress_data['blobs_total'] = total
    migration.progress_data['bytes_uploaded'] = bytes_uploaded
    migration.progress_data['last_progress_update'] = Time.current.iso8601
    migration.save!

    logger.debug("Upload progress: #{uploaded}/#{total} blobs (#{format_bytes(bytes_uploaded)})")
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
