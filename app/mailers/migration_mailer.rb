class MigrationMailer < ApplicationMailer
  default from: ENV.fetch('MAILER_FROM_EMAIL', 'noreply@eurosky-migration.local')

  def backup_ready(migration)
    @migration = migration
    @download_url = migration_download_backup_url(migration, token: migration.token, host: ENV.fetch('DOMAIN', 'localhost:3001'))
    @expires_at = migration.backup_expires_at
    @backup_size = migration.backup_size

    mail(
      to: migration.email,
      subject: "Your Eurosky Migration Backup is Ready (#{migration.token})"
    )
  end
end
