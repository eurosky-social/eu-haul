# Previews of every MigrationMailer email, at /rails/mailers/migration_mailer
# in development. Each one renders from an unsaved Migration: nothing is
# written to the database and nothing is sent. Add ?locale=de (or any other
# configured locale) to a preview's URL to see the mail in that language.
class MigrationMailerPreview < ActionMailer::Preview
  PASSWORD = 'kV7pQ2mZ9xL4wR8tN3bH6cJd'

  def email_verification
    MigrationMailer.email_verification(migration(status: 'pending_account'))
  end

  def account_password
    MigrationMailer.account_password(migration(status: 'pending_download'), PASSWORD)
  end

  def account_password_without_backup
    MigrationMailer.account_password(migration(status: 'pending_account', create_backup_bundle: false), PASSWORD)
  end

  def backup_ready
    MigrationMailer.backup_ready(with_backup(migration(status: 'backup_ready')))
  end

  def rotation_key_notice
    MigrationMailer.rotation_key_notice(migration(status: 'pending_plc'))
  end

  def plc_token_reminder
    MigrationMailer.plc_token_reminder(migration(
      status: 'pending_plc',
      progress_data: { 'plc_token_requested_at' => 26.hours.ago.iso8601, 'plc_reminder_count' => 1 }
    ))
  end

  def migration_completed
    MigrationMailer.migration_completed(with_backup(completed_migration), PASSWORD)
  end

  # Files still in transfer at completion: the password warnings change.
  def migration_completed_with_files_pending
    MigrationMailer.migration_completed(
      completed_migration(failed_blobs: %w[bafkreia5ekqc6f2n3nkg3qnsdfxnl3byaxsc6fj7ue3prbsr2kgb5v3q4y bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku]),
      PASSWORD
    )
  end

  def blobs_transfer_complete
    MigrationMailer.blobs_transfer_complete(completed_migration)
  end

  def blobs_transfer_incomplete
    MigrationMailer.blobs_transfer_incomplete(completed_migration, 3)
  end

  def migration_failed
    MigrationMailer.migration_failed(migration(
      status: 'failed',
      current_job_step: 'UploadBlobsJob',
      last_error: 'Net::ReadTimeout: timed out after 60 seconds while uploading blob bafkreia5ekqc6f2n3nkg3qnsdfxnl3byaxsc6fj7ue3prbsr2kgb5v3q4y',
      retry_count: 2
    ))
  end

  # The expired-PLC-token branch of the same mail.
  def migration_failed_plc_token_expired
    MigrationMailer.migration_failed(migration(
      status: 'failed',
      current_job_step: 'UpdatePlcJob',
      last_error: 'PLC token has expired. Please request a new one.',
      retry_count: 1
    ))
  end

  # The email-taken branch: no retry, the way out instead.
  def migration_failed_email_taken
    MigrationMailer.migration_failed(migration(
      status: 'failed',
      current_job_step: 'CreateAccountJob',
      error_code: 'email_taken',
      last_error: 'The email address jane@example.eu is already used by another account on https://eurosky.social. ' \
                  'Sign in to that account on https://eurosky.social and delete it or change its email address, then start a new migration.',
      target_pds_contact_email: 'admin@eurosky.social'
    ))
  end

  # The one-off follow-up to migrations that stopped on a taken address.
  def email_taken_followup
    MigrationMailer.email_taken_followup(migration(
      status: 'failed',
      current_job_step: 'CreateAccountJob',
      error_code: 'generic',
      last_error: 'Failed to create account on new PDS: Email already taken: jane@example.eu',
      target_pds_contact_email: 'admin@eurosky.social',
      created_at: 45.days.ago
    ))
  end

  def plc_token_failed
    MigrationMailer.plc_token_failed(migration(
      status: 'pending_plc',
      last_error: 'InvalidToken: Token is invalid or expired'
    ))
  end

  def critical_plc_failure
    MigrationMailer.critical_plc_failure(migration(
      status: 'failed',
      last_error: 'PLC operation failed: 500 Internal Server Error from https://plc.directory/did:plc:ewvi7nxzyoun6zhxrhs64oiz'
    ))
  end

  def reauthentication_required
    MigrationMailer.reauthentication_required(migration(
      status: 'pending_blobs',
      current_job_step: 'UploadBlobsJob',
      last_error: 'ExpiredToken: Token has expired'
    ))
  end

  def invalid_invite_code
    MigrationMailer.invalid_invite_code(migration(status: 'failed', last_error: 'InvalidInviteCode: Provided invite code not available'))
  end

  def orphaned_account_error
    MigrationMailer.orphaned_account_error(migration(status: 'failed', target_pds_contact_email: 'support@eurosky.social'))
  end

  def cancellation_confirmation
    MigrationMailer.cancellation_confirmation(migration(
      status: 'pending_blobs',
      progress_data: { 'cancellation_token' => 'c4f1e8b2a9d74e3f' }
    ))
  end

  private

  def migration(**attributes)
    progress_data = { 'rotation_key_public' => 'did:key:zDnaeRvGvJZ8VUYm8SRQtgUeYWwxD3ZT6Uu1DJBqm1oSTjbsC' }
                    .merge(attributes.delete(:progress_data) || {})

    Migration.new(
      token: 'EURO-AB12CD34EF56GH78',
      did: 'did:plc:ewvi7nxzyoun6zhxrhs64oiz',
      email: 'jane@example.eu',
      old_handle: 'jane.bsky.social',
      new_handle: 'jane.eurosky.social',
      old_pds_host: 'https://bsky.social',
      new_pds_host: 'https://eurosky.social',
      email_verification_token: 'K7Q-4ZP',
      rotation_key: 'z42tnbHmmZBkYPYwMT8Nnm4fn4YCvsCNMRxbTjRiZLzNRaAz',
      locale: preview_locale,
      progress_data: progress_data,
      **attributes
    )
  end

  def completed_migration(failed_blobs: nil)
    progress_data = { 'completed_at' => Time.current.change(min: 42).iso8601 }
    progress_data['failed_blobs'] = failed_blobs if failed_blobs
    migration(status: 'completed', progress_data: progress_data)
  end

  # A backup bundle for the mails that offer one, without a file on disk.
  def with_backup(record)
    record.backup_expires_at = 24.hours.from_now
    record.define_singleton_method(:backup_available?) { true }
    record.define_singleton_method(:backup_size) { 48_234_567 }
    record
  end

  def preview_locale
    locale = params[:locale].to_s
    I18n.available_locales.map(&:to_s).include?(locale) ? locale : 'en'
  end
end
