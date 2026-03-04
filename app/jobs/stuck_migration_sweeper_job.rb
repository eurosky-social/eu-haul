# StuckMigrationSweeperJob - Safety net for orphaned migrations
#
# Periodically checks for migrations that are stuck in a pending_* status
# with no corresponding Sidekiq job queued, scheduled, or retrying.
#
# Root cause: the advance_to_* methods update the DB status and then enqueue
# the next job. If the enqueue fails (Redis hiccup, connection pool exhaustion),
# the migration is left in the new status with no job to process it.
# The advance_with_job! fix prevents new occurrences, but this sweeper
# catches any that slip through or were orphaned before the fix.
#
# Schedule: Every 5 minutes via sidekiq-scheduler
# Queue: low (never blocks migration work)

class StuckMigrationSweeperJob < ApplicationJob
  queue_as :low

  # How long a migration must be idle before we consider it stuck.
  # Must be long enough to avoid re-enqueuing jobs that are legitimately
  # in progress (e.g., a large blob transfer can take several minutes).
  STUCK_THRESHOLD = 10.minutes

  # Statuses that should have an active job processing them.
  # Excludes pending_plc (waiting for user action) and terminal states.
  ACTIVE_STATUSES = %w[
    pending_download
    pending_backup
    backup_ready
    pending_account
    pending_repo
    pending_blobs
    pending_prefs
    pending_activation
  ].freeze

  def perform
    stuck = find_stuck_migrations
    return if stuck.empty?

    logger.info("[Sweeper] Found #{stuck.count} potentially stuck migrations, checking Sidekiq queues")

    # Collect all migration IDs that have a job somewhere in Sidekiq
    active_migration_ids = collect_active_sidekiq_migration_ids

    re_enqueued = 0
    stuck.find_each do |migration|
      next if active_migration_ids.include?(migration.id)

      logger.warn(
        "[Sweeper] Re-enqueuing job for stuck migration #{migration.token} " \
        "(status=#{migration.status}, idle since #{migration.updated_at})"
      )

      begin
        enqueue_job_for_status(migration)
        re_enqueued += 1
      rescue => e
        logger.error("[Sweeper] Failed to re-enqueue job for #{migration.token}: #{e.message}")
      end
    end

    logger.info("[Sweeper] Re-enqueued #{re_enqueued} stuck migrations") if re_enqueued > 0
  end

  private

  def find_stuck_migrations
    Migration.where(status: ACTIVE_STATUSES)
             .where("updated_at < ?", STUCK_THRESHOLD.ago)
  end

  # Scan all Sidekiq queues, scheduled set, and retry set to find
  # which migration IDs have a job in flight.
  def collect_active_sidekiq_migration_ids
    ids = Set.new

    # Check all queues
    Sidekiq::Queue.all.each do |queue|
      queue.each do |job|
        migration_id = extract_migration_id(job)
        ids.add(migration_id) if migration_id
      end
    end

    # Check scheduled (future) jobs
    Sidekiq::ScheduledSet.new.each do |job|
      migration_id = extract_migration_id(job)
      ids.add(migration_id) if migration_id
    end

    # Check retry set
    Sidekiq::RetrySet.new.each do |job|
      migration_id = extract_migration_id(job)
      ids.add(migration_id) if migration_id
    end

    ids
  end

  # ActiveJob wraps args in a hash with 'arguments' key inside the Sidekiq payload.
  # The migration_id is always the first argument to our jobs.
  def extract_migration_id(job)
    args = job.args
    if args.is_a?(Array) && args.first.is_a?(Hash)
      # ActiveJob format: [{"job_class"=>..., "arguments"=>[migration_id]}]
      args.first.dig('arguments')&.first
    elsif args.is_a?(Array)
      args.first
    end
  end

  def enqueue_job_for_status(migration)
    case migration.status
    when 'pending_download'
      DownloadAllDataJob.perform_later(migration.id)
    when 'pending_backup'
      CreateBackupBundleJob.perform_later(migration.id)
    when 'backup_ready', 'pending_account'
      CreateAccountJob.perform_later(migration.id)
    when 'pending_repo'
      if migration.create_backup_bundle && migration.downloaded_data_path.present?
        UploadRepoJob.perform_later(migration.id)
      else
        ImportRepoJob.perform_later(migration.id)
      end
    when 'pending_blobs'
      if migration.create_backup_bundle && migration.downloaded_data_path.present?
        UploadBlobsJob.perform_later(migration.id)
      else
        ImportBlobsJob.perform_later(migration.id)
      end
    when 'pending_prefs'
      ImportPrefsJob.perform_later(migration.id)
    when 'pending_activation'
      ActivateAccountJob.perform_later(migration.id)
    else
      logger.warn("[Sweeper] Unknown status for migration #{migration.token}: #{migration.status}")
    end
  end
end
