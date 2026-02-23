# WaitForPlcTokenJob - Placeholder job for user PLC token submission
#
# This job does NOT perform any actual migration work. It simply logs that
# the migration is waiting for user input via the web form.
#
# Status Flow:
#   pending_plc -> (waits for user to submit PLC token via web form)
#
# The actual advancement to the next stage happens when:
#   1. User receives PLC token via email
#   2. User submits token through web form
#   3. MigrationsController calls migration.advance_to_pending_activation!
#   4. UpdatePlcJob is enqueued automatically
#
# Retries: false (this job is idempotent and does nothing)
# Queue: :migrations
#
# Note: This job exists to maintain consistency in the migration flow
# and provide clear logging that the system is waiting for user action.

class WaitForPlcTokenJob < ApplicationJob
  queue_as :migrations
  # No retries needed - this job just logs and requests token

  def perform(migration_id)
    migration = Migration.find(migration_id)
    Rails.logger.info("Migration #{migration.token} is now pending PLC token submission")
    Rails.logger.info("DID: #{migration.did}")
    Rails.logger.info("User must submit PLC token via web form at /migrations/#{migration.token}")
    Rails.logger.info("Once token is submitted, UpdatePlcJob will be enqueued automatically")

    # Idempotency check: Skip if already past this stage
    if migration.status != 'pending_plc'
      Rails.logger.info("Migration #{migration.token} is already at status '#{migration.status}', skipping PLC token wait")
      return
    end

    service = GoatService.new(migration)

    # Step 1: Generate rotation key BEFORE requesting PLC token
    # The user needs this safety net before the point of no return.
    # By sending it now, they receive the recovery key email before the
    # PLC token email from Bluesky, giving them time to save it.
    unless migration.rotation_key.present?
      Rails.logger.info("Generating rotation key before PLC token request (safety net)")
      rotation_key = service.generate_rotation_key
      migration.set_rotation_key(rotation_key[:private_key])
      migration.progress_data['rotation_key_public'] = rotation_key[:public_key]
      migration.progress_data['rotation_key_generated_at'] = Time.current.iso8601
      migration.save!
      Rails.logger.info("Rotation key generated and stored (public key: #{rotation_key[:public_key]})")

      # Send rotation key email — user's safety net before the point of no return
      begin
        MigrationMailer.rotation_key_notice(migration).deliver_later
        Rails.logger.info("Rotation key notice email queued for #{migration.email}")
      rescue StandardError => e
        # Don't block migration if email fails — key is safely in the DB
        Rails.logger.warn("Failed to send rotation key email: #{e.message}")
      end
    else
      Rails.logger.info("Rotation key already exists, skipping generation")
    end

    # Step 2: Request PLC token from old PDS (sends email to user from their old provider)
    begin
      service.request_plc_token

      # Update progress to indicate token was requested
      migration.progress_data['plc_token_requested_at'] = Time.current.iso8601
      migration.save!

      Rails.logger.info("PLC token request sent to old PDS for migration #{migration.token}")
      Rails.logger.info("User will receive PLC token via email from #{migration.old_pds_host}")
    rescue StandardError => e
      Rails.logger.error("Failed to request PLC token for migration #{migration.token}: #{e.message}")
      migration.mark_failed!("Failed to request PLC token: #{e.message}")
      raise
    end

    # This job completes here. The next step (UpdatePlcJob) is triggered
    # manually when the user submits the PLC token via the web form.
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error("Migration not found: #{migration_id}")
    raise
  end
end
