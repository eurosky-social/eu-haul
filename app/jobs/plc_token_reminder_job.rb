# PlcTokenReminderJob - Sends periodic reminders to users stuck at pending_plc
#
# Runs every 6 hours via Sidekiq scheduler. Finds migrations that have been
# waiting for PLC token submission and sends a reminder email.
#
# Only sends reminders if:
#   - Migration is in pending_plc status
#   - PLC token was requested at least 6 hours ago
#   - No reminder was sent in the last 6 hours
#
# Queue: :low (non-urgent, should not compete with migration jobs)

class PlcTokenReminderJob < ApplicationJob
  queue_as :low

  def perform
    migrations = Migration.pending_plc
      .where("progress_data->>'plc_token_requested_at' IS NOT NULL")

    reminded = 0
    skipped = 0

    migrations.find_each do |migration|
      requested_at = Time.parse(migration.progress_data['plc_token_requested_at']) rescue nil
      next unless requested_at

      # Only remind if at least 6 hours since token was requested
      next if requested_at > 6.hours.ago

      # Only remind if no reminder sent in last 6 hours
      last_reminder = migration.progress_data['plc_reminder_sent_at']
      if last_reminder.present?
        last_reminder_time = Time.parse(last_reminder) rescue nil
        if last_reminder_time && last_reminder_time > 6.hours.ago
          skipped += 1
          next
        end
      end

      begin
        MigrationMailer.plc_token_reminder(migration).deliver_later
        migration.progress_data['plc_reminder_sent_at'] = Time.current.iso8601
        migration.progress_data['plc_reminder_count'] = (migration.progress_data['plc_reminder_count'].to_i + 1)
        migration.save!
        reminded += 1
      rescue StandardError => e
        Rails.logger.warn("Failed to send PLC reminder for #{migration.token}: #{e.message}")
      end
    end

    Rails.logger.info("PlcTokenReminderJob: sent #{reminded} reminders, skipped #{skipped}")
  end
end
