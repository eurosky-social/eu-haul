# Configure Active Record Encryption from environment variables
# This must run before any models are loaded that use the encrypts method

Rails.application.config.before_initialize do
  Rails.application.config.active_record.encryption.primary_key = ENV['ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY']
  Rails.application.config.active_record.encryption.deterministic_key = ENV['ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY']
  Rails.application.config.active_record.encryption.key_derivation_salt = ENV['ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT']
end
