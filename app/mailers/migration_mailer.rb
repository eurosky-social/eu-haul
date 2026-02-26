class MigrationMailer < ApplicationMailer
  # from and reply_to inherited from ApplicationMailer

  def account_password(migration, password)
    @migration = migration
    @password = password
    @migration_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))

    I18n.with_locale(migration.locale || :en) do
      mail(
        to: migration.email,
        subject: I18n.t('mailers.account_password.subject', handle: migration.new_handle, token: migration.token)
      )
    end
  end

  def backup_ready(migration)
    @migration = migration
    @download_url = migration_download_backup_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))
    @expires_at = migration.backup_expires_at
    @backup_size = migration.backup_size

    I18n.with_locale(migration.locale || :en) do
      mail(
        to: migration.email,
        subject: I18n.t('mailers.backup_ready.subject', token: migration.token)
      )
    end
  end

  def migration_failed(migration)
    @migration = migration
    @migration_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))
    @error_message = migration.last_error
    @failed_step = migration.current_job_step || migration.status
    @retry_count = migration.retry_count

    I18n.with_locale(migration.locale || :en) do
      mail(
        to: migration.email,
        subject: I18n.t('mailers.migration_failed.subject', token: migration.token)
      )
    end
  end

  def migration_completed(migration, new_account_password = nil)
    @migration = migration
    @password = new_account_password
    @migration_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))
    @backup_available = migration.backup_available?
    @download_url = migration_download_backup_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001')) if @backup_available
    @completed_at = migration.progress_data['completed_at']

    I18n.with_locale(migration.locale || :en) do
      mail(
        to: migration.email,
        subject: I18n.t('mailers.migration_completed.subject', token: migration.token)
      )
    end
  end

  def email_verification(migration)
    @migration = migration
    @status_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))

    I18n.with_locale(migration.locale || :en) do
      mail(
        to: migration.email,
        subject: I18n.t('mailers.email_verification.subject', code: migration.email_verification_token, token: migration.token)
      )
    end
  end

  def rotation_key_notice(migration)
    @migration = migration
    @rotation_key_private = migration.rotation_key
    @rotation_key_public = migration.progress_data['rotation_key_public']
    @migration_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))

    I18n.with_locale(migration.locale || :en) do
      mail(
        to: migration.email,
        subject: I18n.t('mailers.rotation_key_notice.subject', token: migration.token)
      )
    end
  end

  def plc_token_failed(migration)
    @migration = migration
    @migration_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))
    @error_message = migration.last_error

    I18n.with_locale(migration.locale || :en) do
      mail(
        to: migration.email,
        subject: I18n.t('mailers.plc_token_failed.subject', token: migration.token)
      )
    end
  end

  def critical_plc_failure(migration)
    @migration = migration
    @migration_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))
    @error_message = migration.last_error
    @rotation_key = migration.rotation_key
    @support_email = ENV.fetch('SUPPORT_EMAIL', 'support@example.com')

    I18n.with_locale(migration.locale || :en) do
      mail(
        to: migration.email,
        subject: I18n.t('mailers.critical_plc_failure.subject', token: migration.token),
        priority: 1 # High priority
      )
    end
  end

  def failed_blobs_retry_complete(migration, successful_count, failed_count)
    @migration = migration
    @migration_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))
    @successful_count = successful_count
    @failed_count = failed_count
    @can_retry_again = failed_count > 0

    I18n.with_locale(migration.locale || :en) do
      mail(
        to: migration.email,
        subject: I18n.t('mailers.failed_blobs_retry_complete.subject', successful_count: successful_count, failed_count: failed_count, token: migration.token)
      )
    end
  end

  def invalid_invite_code(migration)
    @migration = migration
    @new_migration_url = new_migration_url(host: ENV.fetch('DOMAIN', 'localhost:3001'))

    I18n.with_locale(migration.locale || :en) do
      mail(
        to: migration.email,
        subject: I18n.t('mailers.invalid_invite_code.subject', token: migration.token)
      )
    end
  end

  def orphaned_account_error(migration)
    @migration = migration
    @migration_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))
    @target_pds_support_email = migration.target_pds_contact_email.presence || ENV.fetch('SUPPORT_EMAIL', 'support@example.com')

    I18n.with_locale(migration.locale || :en) do
      mail(
        to: migration.email,
        subject: I18n.t('mailers.orphaned_account_error.subject', token: migration.token)
      )
    end
  end

  def reauthentication_required(migration)
    @migration = migration
    @migration_url = migration_by_token_url(token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))
    @error_message = migration.last_error
    @failed_step = migration.current_job_step || migration.status

    I18n.with_locale(migration.locale || :en) do
      mail(
        to: migration.email,
        subject: I18n.t('mailers.reauthentication_required.subject', token: migration.token)
      )
    end
  end

  def cancellation_confirmation(migration)
    @migration = migration
    @confirm_url = confirm_cancellation_by_token_url(
      token: migration.token,
      cancellation_token: migration.progress_data['cancellation_token'],
      host: ENV.fetch('DOMAIN', 'localhost:3001')
    )

    I18n.with_locale(migration.locale || :en) do
      mail(
        to: migration.email,
        subject: I18n.t('mailers.cancellation_confirmation.subject', token: migration.token)
      )
    end
  end
end
