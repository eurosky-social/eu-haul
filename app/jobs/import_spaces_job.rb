# ImportSpacesJob - moves the account's atproto spaces to the new PDS
#
# Spaces are permissioned data (private posts, groups, gated content, ...)
# kept outside the public repo, so the repo and blob stages don't carry them.
# Left behind, the spaces the account runs would stop working for every
# member once the DID points to the new PDS, and the account's records in
# other spaces would look deleted.
#
# Status Flow:
#   pending_spaces -> pending_prefs
#
# What This Job Does:
#   1. Lists the account's spaces on the old PDS (none when it has no spaces,
#      or no spaces support). Accounts without spaces stop here and never
#      call the new PDS's spaces endpoints.
#   2. Moves them with SpaceTransferService
#   3. Stops the migration - before the PLC step - when the new PDS turns
#      out not to implement spaces (its first import answers "not
#      implemented"; nothing was written there), or refuses the data
#   4. Records whether the new PDS took spaces (UpdatePlcJob logs the KEM key
#      against it) and advances to pending_prefs
#
# Files that keep failing are recorded in progress_data['failed_space_blobs']
# and tried again by ActivateAccountJob's re-sync; they don't stop the stage.
#
# Retries: 3 times (imports replace what the new PDS holds, so a rerun is safe)
# Queue: :migrations (moves files, like the blob stage)

class ImportSpacesJob < ApplicationJob
  queue_as :migrations
  retry_on StandardError, wait: :polynomially_longer, attempts: 3
  retry_on GoatService::RateLimitError, wait: :polynomially_longer, attempts: 5

  def perform(migration_id)
    migration = Migration.find(migration_id)
    Rails.logger.info("[ImportSpacesJob] Starting spaces transfer for migration #{migration.token} (#{migration.did})")

    # Idempotency check: Skip if already past this stage
    if migration.status != 'pending_spaces'
      Rails.logger.info("[ImportSpacesJob] Migration #{migration.token} is already at status '#{migration.status}', skipping")
      return
    end

    goat = GoatService.new(migration)

    # Step 1: the account's spaces. A PDS without spaces can't hold any.
    spaces = begin
      goat.list_spaces(:old)
    rescue GoatService::SpacesUnsupportedError
      Rails.logger.info("[ImportSpacesJob] Old PDS #{migration.old_pds_host} has no spaces support")
      []
    end

    migration.merge_progress!('spaces_total' => spaces.length, 'spaces_checked_at' => Time.current.iso8601)

    if spaces.any?
      # Step 2: move them
      migration.merge_progress!('spaces_started_at' => Time.current.iso8601)
      result = begin
        SpaceTransferService.new(migration, goat: goat).transfer(spaces)
      rescue GoatService::SpacesUnsupportedError => e
        # Step 3: never leave spaces behind silently
        Rails.logger.warn("[ImportSpacesJob] #{migration.token}: #{spaces.length} spaces, but " \
                          "#{migration.new_pds_host} has no spaces support (#{e.message})")
        migration.merge_progress!('destination_supports_spaces' => false)
        migration.mark_failed!(
          "Spaces not supported: #{migration.new_pds_host} can't take the account's #{spaces.length} spaces",
          error_code: :spaces_unsupported
        )
        return
      end

      # Step 4: record the outcome
      migration.merge_progress!(
        'destination_supports_spaces' => true,
        'spaces_moved' => result.spaces,
        'space_repos_moved' => result.repos,
        'space_blobs_moved' => result.blobs,
        'failed_space_blobs' => result.failed_blobs,
        'spaces_completed_at' => Time.current.iso8601
      )
    end

    # Next stage
    Rails.logger.info("[ImportSpacesJob] Spaces done for #{migration.token} (#{spaces.length} spaces), advancing to pending_prefs")
    migration.advance_to_pending_prefs!

  rescue Migration::Aborted => e
    # Cancelled, failed or completed underneath us - stop without retrying
    Rails.logger.warn("[ImportSpacesJob] #{e.message}")

  rescue ActiveRecord::RecordNotFound
    Rails.logger.error("[ImportSpacesJob] Migration not found: #{migration_id}")

  rescue GoatService::SpaceImportRejectedError => e
    # The new PDS refused the data itself; the same import would fail again
    Rails.logger.error("[ImportSpacesJob] New PDS rejected space data for #{migration.token}: #{e.message}")
    migration.mark_failed!("Spaces rejected by the new PDS: #{e.message}", error_code: :spaces_rejected)

  rescue GoatService::RateLimitError => e
    Rails.logger.warn("[ImportSpacesJob] Rate limit hit for migration #{migration&.token}: #{e.message}")
    migration&.update(last_error: "Rate limit: #{e.message}")
    raise # retry with polynomially_longer backoff

  rescue StandardError => e
    Rails.logger.error("[ImportSpacesJob] Spaces transfer failed for migration #{migration&.token || migration_id}: #{e.message}")
    handle_error(migration, e)
  end

  private

  # Like the repo stage: retry, and mark the migration failed only once the
  # attempts are used up
  def handle_error(migration, error)
    return unless migration

    migration.reload
    if executions >= 3
      Rails.logger.error("[ImportSpacesJob] All retries exhausted for migration #{migration.token}, marking as failed")
      error_code = error.is_a?(GoatService::AuthenticationError) ? :authentication : :generic
      migration.mark_failed!("Spaces transfer failed: #{error.message}", error_code: error_code)
    else
      Rails.logger.info("[ImportSpacesJob] Will retry (attempt #{executions}/3) for migration #{migration.token}")
      migration.update(last_error: "Spaces transfer: #{error.message}")
      raise error
    end
  end
end
