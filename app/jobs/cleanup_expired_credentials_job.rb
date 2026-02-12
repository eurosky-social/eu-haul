# CleanupExpiredCredentialsJob - Purges expired credentials from database
#
# Purpose:
#   Securely removes encrypted passwords and PLC tokens that have expired
#   to minimize security risk from database compromise.
#
# What This Job Does:
#   1. Finds migrations with expired credentials (credentials_expires_at < now)
#   2. Clears encrypted_password and encrypted_plc_token
#   3. Logs cleanup statistics
#
# Security Rationale:
#   - PLC tokens are single-use and short-lived (max 1 hour) - always safe to clear
#   - Passwords (for new PDS) and old PDS tokens are needed until PLC update completes
#   - For pre-PLC migrations, only the PLC token is cleared (password + old tokens kept)
#   - For post-PLC or abandoned (failed > 7 days) migrations, all credentials cleared
#   - Keeping expired credentials increases attack surface
#   - GDPR compliance: data minimization principle
#
# Scheduling:
#   Run via cron every 6 hours:
#   ```
#   0 */6 * * * cd /app && rails runner "CleanupExpiredCredentialsJob.perform_now"
#   ```
#
#   Or via Sidekiq scheduler (if sidekiq-scheduler is installed):
#   ```yaml
#   cleanup_expired_credentials:
#     cron: '0 */6 * * *'
#     class: CleanupExpiredCredentialsJob
#   ```
#
# Manual Execution:
#   # Via Rails runner (recommended for cron)
#   rails runner "CleanupExpiredCredentialsJob.perform_now"
#
#   # Via Sidekiq (async)
#   CleanupExpiredCredentialsJob.perform_later
#
# Notes:
#   - Only affects migrations with expired credentials
#   - Active migrations (within expiration window) are not touched
#   - Completed migrations already have credentials cleared by ActivateAccountJob
#   - Failed migrations may retain credentials past expiration for retry attempts
#
# Example Output:
#   [CleanupExpiredCredentialsJob] Starting cleanup of expired credentials
#   [CleanupExpiredCredentialsJob] Found 5 migrations with expired credentials
#   [CleanupExpiredCredentialsJob] Cleared credentials for EURO-ABC12345 (completed, expired 2 hours ago)
#   [CleanupExpiredCredentialsJob] Cleared credentials for EURO-XYZ67890 (failed, expired 12 hours ago)
#   [CleanupExpiredCredentialsJob] Cleanup complete: 5 cleaned, 0 failed

class CleanupExpiredCredentialsJob < ApplicationJob
  queue_as :low

  def perform
    logger.info("[CleanupExpiredCredentialsJob] Starting cleanup of expired credentials")

    # Find migrations with expired credentials that still have encrypted data
    expired_migrations = Migration
      .where("credentials_expires_at < ?", Time.current)
      .where(
        "encrypted_password IS NOT NULL OR encrypted_plc_token IS NOT NULL OR " \
        "encrypted_old_access_token IS NOT NULL OR encrypted_old_refresh_token IS NOT NULL"
      )

    if expired_migrations.empty?
      logger.info("[CleanupExpiredCredentialsJob] No expired credentials found")
      return
    end

    logger.info("[CleanupExpiredCredentialsJob] Found #{expired_migrations.count} migrations with expired credentials")

    cleaned_count = 0
    failed_count = 0

    expired_migrations.find_each do |migration|
      begin
        # Calculate how long ago credentials expired (for logging)
        expired_ago = ((Time.current - migration.credentials_expires_at) / 1.hour).round(1)

        # The password (for new PDS login) and old PDS tokens are needed until
        # the PLC update is complete. Only clear them for migrations that are
        # past the PLC step (pending_activation/completed), or that have been
        # abandoned (failed for over 7 days). For active/recent failures, keep
        # these credentials so the user can still retry/re-request a PLC token.
        plc_step_done = %w[pending_activation completed].include?(migration.status)
        abandoned = migration.failed? && migration.updated_at < 7.days.ago

        # Always safe to clear the PLC token itself (it's single-use / short-lived)
        attrs_to_clear = {
          encrypted_plc_token: nil
        }

        if plc_step_done || abandoned
          # PLC step is done or migration is abandoned - clear everything
          attrs_to_clear[:encrypted_password] = nil
          attrs_to_clear[:encrypted_old_access_token] = nil
          attrs_to_clear[:encrypted_old_refresh_token] = nil
        end

        migration.update!(attrs_to_clear)

        cleared_what = plc_step_done || abandoned ? "all credentials" : "PLC token only (kept password + old PDS tokens)"
        logger.info(
          "[CleanupExpiredCredentialsJob] Cleared #{cleared_what} for #{migration.token} " \
          "(status: #{migration.status}, expired #{expired_ago}h ago)"
        )

        cleaned_count += 1

      rescue StandardError => e
        logger.error("[CleanupExpiredCredentialsJob] Failed to cleanup #{migration.token}: #{e.message}")
        failed_count += 1
      end
    end

    logger.info(
      "[CleanupExpiredCredentialsJob] Cleanup complete: " \
      "#{cleaned_count} cleaned, #{failed_count} failed"
    )

  rescue StandardError => e
    logger.error("[CleanupExpiredCredentialsJob] Unexpected error: #{e.message}")
    logger.error(e.backtrace.join("\n"))
    raise
  end
end
