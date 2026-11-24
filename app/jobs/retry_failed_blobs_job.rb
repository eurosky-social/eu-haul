# RetryFailedBlobsJob - Retry specific blobs that failed during migration
#
# This job allows users to retry only the blobs that failed during the
# initial ImportBlobsJob, without re-running the entire migration.
#
# Flow:
# 1. Receives migration ID and list of failed blob CIDs
# 2. Logs in to new PDS
# 3. Drops the blobs the new PDS already has (listMissingBlobs)
# 4. Takes each remaining blob from the backup bundle, or downloads it from
#    the old PDS
# 5. Uploads each blob to new PDS; when the new PDS refuses uploads until its
#    quota comes back, leaves the rest for a pass at that time
# 6. Sends the space files the upload quota left behind
#    (progress_data['failed_space_blobs'], see SpaceTransferService) from
#    their kept copies: they count against the same quota
# 7. Updates progress_data to remove successfully retried blobs
# 8. Reports final success/failure count
#
# Queue: :migrations
# Retry: 3 attempts

class RetryFailedBlobsJob < ApplicationJob
  queue_as :migrations
  retry_on StandardError, wait: :polynomially_longer, attempts: 3
  retry_on GoatService::RateLimitError, wait: :polynomially_longer, attempts: 5

  MAX_BLOB_RETRIES = 3

  # Background passes after the blob stage: UploadBlobsJob schedules pass 1
  # (15 minutes later); a pass that still leaves blobs behind schedules the
  # next one with these delays. The target PDS has rejected uploads for up to
  # an hour at a stretch, so a single retry would often land inside the same
  # outage. Manual retries from the status page are unlimited.
  AUTO_RETRY_DELAYS = [1.hour, 4.hours].freeze

  # How long after the reset time the new PDS names a pass waiting for its
  # upload quota starts: room for clock differences between us and the PDS.
  QUOTA_RESET_MARGIN = 2.minutes

  # The new PDS refused an upload until reset_at, hours away: bsky.social
  # takes 1,000 files per account per day. Schedule the next background pass
  # for then and record when it starts, for the status page and for how long
  # a completed migration keeps the new-PDS session that pass signs in with.
  def self.schedule_after_quota(migration, cids, auto_attempt, error)
    retry_at = error.reset_at + QUOTA_RESET_MARGIN
    set(wait_until: retry_at).perform_later(migration.id, cids, auto_attempt)
    migration.merge_progress!(
      'blobs_quota_retry_at' => retry_at.utc.iso8601,
      'blobs_quota_limit' => error.limit,
      'blobs_auto_retry_scheduled_at' => Time.current.iso8601,
      'blobs_auto_retry_exhausted_at' => nil
    )
    if Migration.where(id: migration.id).pick(:status) == 'completed'
      Migration.where(id: migration.id).update_all(credentials_expires_at: migration.retry_session_expires_at)
    end
    Rails.logger.info("New PDS refuses uploads for #{migration.token} until #{error.reset_at.utc.iso8601} " \
                      "(limit #{error.limit.inspect}); pass #{auto_attempt} for #{cids.length} files " \
                      "scheduled at #{retry_at.utc.iso8601}")
  end

  # Space files the quota stopped (ImportSpacesJob, the re-sync before
  # activation) go with the pass already coming for the public files when
  # there is one: both count against the same quota, and two chains would
  # spend it twice. Otherwise they get a pass of their own at the reset.
  def self.schedule_for_space_files(migration, error)
    if migration.blob_retry_chain_pending?
      Rails.logger.info("Space files of #{migration.token} wait for the file pass already scheduled")
      return
    end

    schedule_after_quota(migration, migration.missing_public_blobs, 1, error)
  end

  # auto_attempt: nil for a user-triggered retry, 1.. for the background passes
  def perform(migration_id, failed_blob_cids, auto_attempt = nil)
    migration = Migration.find(migration_id)
    logger.info("Retrying #{failed_blob_cids.length} failed blobs for migration #{migration.token}" \
                "#{auto_attempt ? " (automatic pass #{auto_attempt})" : ''}")

    # Scheduled automatically by UploadBlobsJob as well as by the status page;
    # a cancelled/failed migration must not be touched any more.
    if migration.failed?
      logger.info("Migration #{migration.token} is failed or cancelled; not retrying blobs")
      return
    end

    # A completed migration with no files missing is done: an earlier pass or
    # a manual retry moved them and cleared the session this pass would sign
    # in with.
    if migration.completed? && !migration.files_missing?
      logger.info("Migration #{migration.token} is complete with no files missing; nothing to retry")
      return
    end

    # Initialize GoatService
    goat = GoatService.new(migration)

    # Login to new PDS for uploads
    goat.login_new_pds

    # Measure this pass. Retry passes run against a PDS that already refused
    # these blobs once, so their success rate is the interesting one: it says
    # whether the target recovered or is still bad.
    start_blob_pass(migration, pass: BlobTransferTelemetry::PASS_RETRY, goat: goat)

    # Track results
    successful_cids = []
    still_failed_cids = []
    # Set when the new PDS refuses uploads until its quota comes back; the
    # files not tried yet then wait for the pass scheduled for that time.
    quota_error = nil

    # Files the new PDS already has (an earlier pass, an upload whose answer
    # got lost) need no upload. Every upload counts against the quota, so
    # sending them again would push the missing ones into the next day.
    to_upload = failed_blob_cids
    if (missing = goat.missing_blob_cids)
      to_upload, already_there = failed_blob_cids.partition { |cid| missing.include?(cid) }
      successful_cids.concat(already_there)
      logger.info("#{already_there.length} of these files are already on the new PDS") if already_there.any?
    end

    # Process each failed blob
    to_upload.each_with_index do |cid, index|
      if quota_error
        skip_blob(cid)
        still_failed_cids << cid
        next
      end

      begin
        logger.info("Retrying blob #{index + 1}/#{to_upload.length}: #{cid}")

        # Prefer the local copy from the backup bundle (no dependency on the
        # old PDS, which may already be deactivated); otherwise download it
        local_path = local_blob_path(migration, cid)
        blob_path = local_path || download_blob_with_retry(goat, cid)

        # Upload blob to new PDS
        upload_blob_with_retry(goat, blob_path)

        # Cleanup (bundle files are kept for the user's download)
        FileUtils.rm_f(blob_path) unless local_path

        successful_cids << cid
        logger.info("Successfully retried blob: #{cid}")

      rescue StandardError => e
        if upload_quota_refusal?(e)
          logger.warn("New PDS refuses uploads until #{e.reset_at.utc.iso8601}; leaving the remaining " \
                      "#{to_upload.length - index} files for then")
          quota_error = e
        else
          logger.error("Failed to retry blob #{cid}: #{e.message}")
        end
        still_failed_cids << cid
      end
    end

    # Space files the upload quota left behind (SpaceTransferService) count
    # against the same quota, so they go with the same pass, after the public
    # ones, unless the quota already stopped those.
    space_entries = migration.missing_space_blobs
    still_failed_space = space_entries
    if space_entries.any? && quota_error.nil?
      still_failed_space, quota_error = SpaceTransferService.new(migration, goat: goat).send_left_over(space_entries)
      logger.info("Space files: #{space_entries.length - still_failed_space.length} of #{space_entries.length} sent")
    end
    remaining = still_failed_cids.length + still_failed_space.length

    # Update migration progress_data (atomic merge - the pipeline may be
    # writing other keys concurrently while the user waits for the PLC token)
    progress = {
      'failed_blobs' => still_failed_cids,
      'failed_uploads' => still_failed_cids,
      'blobs_completed' => migration.progress_data['blobs_completed'].to_i + successful_cids.length,
      'blobs_retry_attempted_at' => Time.current.iso8601,
      'blobs_retry_success_count' => successful_cids.length,
      'blobs_retry_failed_count' => still_failed_cids.length
    }
    progress['failed_space_blobs'] = still_failed_space if space_entries.any?
    migration.merge_progress!(progress)

    # Log summary
    logger.info("Blob retry complete for migration #{migration.token}:")
    logger.info("  Successfully retried: #{successful_cids.length}")
    logger.info("  Still failed: #{still_failed_cids.length}")

    # The user was told in the completion email to keep the new password
    # unchanged until the FINAL mail arrives (a password change revokes the
    # sessions this job needs), so a completed migration must always end in
    # exactly one of the two mails below.
    completed_now = Migration.where(id: migration.id).pick(:status) == 'completed'
    # A pass that got files in before the quota stopped it may run again at
    # the reset without using up one of the automatic passes: a big account
    # needs one such pass per day. One that got nothing in uses one up, so a
    # PDS that keeps refusing still ends the chain.
    progressed = remaining < failed_blob_cids.length + space_entries.length
    next_pass_scheduled = false

    if remaining.zero?
      if completed_now && migration.progress_data['blobs_transfer_complete_mailed_at'].blank?
        migration.merge_progress!('blobs_transfer_complete_mailed_at' => Time.current.iso8601)
        MigrationMailer.blobs_transfer_complete(migration).deliver_later
        logger.info("All files transferred for completed migration #{migration.token}; final mail queued")
      end
    elsif quota_error && auto_attempt && (progressed || auto_attempt <= AUTO_RETRY_DELAYS.length)
      self.class.schedule_after_quota(migration, still_failed_cids, progressed ? auto_attempt : auto_attempt + 1, quota_error)
      next_pass_scheduled = true
    elsif quota_error && auto_attempt.nil? && !migration.blob_retry_chain_pending?
      # A manual retry found the quota used up and no automatic pass is
      # coming: start a chain at the reset, so the status page's "sent from"
      # holds.
      self.class.schedule_after_quota(migration, still_failed_cids, 1, quota_error)
    elsif quota_error && auto_attempt.nil?
      # A pass is already coming; it waits for the quota itself if it has to.
      migration.merge_progress!('blobs_quota_retry_at' => (quota_error.reset_at + QUOTA_RESET_MARGIN).utc.iso8601)
    elsif auto_attempt && auto_attempt <= AUTO_RETRY_DELAYS.length
      # Next background pass, while any are allowed
      delay = AUTO_RETRY_DELAYS[auto_attempt - 1]
      self.class.set(wait: delay).perform_later(migration.id, still_failed_cids, auto_attempt + 1)
      migration.merge_progress!('blobs_auto_retry_scheduled_at' => Time.current.iso8601, 'blobs_auto_retry_exhausted_at' => nil)
      next_pass_scheduled = true
      logger.info("Scheduled automatic pass #{auto_attempt + 1} for #{still_failed_cids.length} blobs in #{delay.inspect}")
    elsif auto_attempt
      migration.merge_progress!('blobs_auto_retry_exhausted_at' => Time.current.iso8601)
      logger.warn("Automatic retries exhausted for migration #{migration.token}; #{remaining} files remain (manual retry available)")
      if completed_now
        MigrationMailer.blobs_transfer_incomplete(migration, remaining).deliver_later
        logger.info("Incomplete-transfer mail queued for #{migration.token}")
      end
    end

    # For a completed migration the chain ends here when every file is in or
    # the automatic passes are used up. Drop the new-PDS session that
    # ActivateAccountJob kept for these passes.
    chain_over = remaining.zero? || (auto_attempt && !next_pass_scheduled)
    if completed_now && chain_over
      migration.clear_credentials!
      logger.info("File retries over for #{migration.token}; cleared the new-PDS session")
    end

  rescue ActiveRecord::RecordNotFound => e
    logger.error("Migration not found: #{migration_id}")
  rescue StandardError => e
    logger.error("Failed blob retry job failed for migration #{migration_id}: #{e.message}")
    logger.error(e.backtrace.join("\n"))
    raise
  ensure
    finish_blob_pass
  end

  private

  # Path of the blob inside the downloaded backup bundle, if it is there
  def local_blob_path(migration, cid)
    return nil if migration.downloaded_data_path.blank?

    path = File.join(migration.downloaded_data_path, 'blobs', cid)
    File.file?(path) ? path : nil
  end

  # Download blob with retry logic
  def download_blob_with_retry(goat, cid, attempt = 1)
    measure(cid: cid, phase: :download) { goat.download_blob(cid) }
  rescue GoatService::RateLimitError => e
    if attempt < MAX_BLOB_RETRIES
      backoff = 2 ** (attempt + 2) # Longer backoff for rate limits: 8s, 16s, 32s
      logger.warn("Rate limit hit downloading blob (attempt #{attempt}/#{MAX_BLOB_RETRIES}): #{cid} - retrying in #{backoff}s")
      pause(backoff)
      download_blob_with_retry(goat, cid, attempt + 1)
    else
      logger.error("Blob download failed after #{MAX_BLOB_RETRIES} rate-limit retries: #{cid}")
      raise
    end
  rescue GoatService::NetworkError, GoatService::TimeoutError => e
    if attempt < MAX_BLOB_RETRIES
      logger.warn("Blob download failed (attempt #{attempt}/#{MAX_BLOB_RETRIES}): #{cid} - #{e.message}")
      pause(2 ** attempt) # Exponential backoff: 2s, 4s, 8s
      download_blob_with_retry(goat, cid, attempt + 1)
    else
      logger.error("Blob download failed after #{MAX_BLOB_RETRIES} attempts: #{cid}")
      raise
    end
  end

  # The new PDS refusing uploads until a reset hours away. A refusal from the
  # old PDS while downloading is not one: it says nothing about the uploads.
  def upload_quota_refusal?(error)
    error.is_a?(GoatService::QuotaExhaustedError) && error.phase == :upload && error.reset_at.present?
  end

  # Upload blob with retry logic
  def upload_blob_with_retry(goat, blob_path, attempt = 1)
    measure(cid: File.basename(blob_path.to_s), bytes: file_size(blob_path)) do
      goat.upload_blob(blob_path)
    end
  rescue GoatService::QuotaExhaustedError
    # Every retry before the reset is refused too; the caller parks the rest.
    raise
  rescue GoatService::RateLimitError => e
    if attempt < MAX_BLOB_RETRIES
      backoff = 2 ** (attempt + 2) # Longer backoff for rate limits: 8s, 16s, 32s
      logger.warn("Rate limit hit uploading blob (attempt #{attempt}/#{MAX_BLOB_RETRIES}): #{blob_path} - retrying in #{backoff}s")
      pause(backoff)
      upload_blob_with_retry(goat, blob_path, attempt + 1)
    else
      logger.error("Blob upload failed after #{MAX_BLOB_RETRIES} rate-limit retries: #{blob_path}")
      raise
    end
  rescue GoatService::NetworkError, GoatService::TimeoutError => e
    if attempt < MAX_BLOB_RETRIES
      logger.warn("Blob upload failed (attempt #{attempt}/#{MAX_BLOB_RETRIES}): #{blob_path} - #{e.message}")
      pause(2 ** attempt) # Exponential backoff: 2s, 4s, 8s
      upload_blob_with_retry(goat, blob_path, attempt + 1)
    else
      logger.error("Blob upload failed after #{MAX_BLOB_RETRIES} attempts: #{blob_path}")
      raise
    end
  end

  # All waits go through here so specs can stub them
  def pause(seconds)
    sleep(seconds)
  end
end
