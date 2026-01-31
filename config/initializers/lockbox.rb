# Be sure to restart your server when you modify this file.
#
# Lockbox encryption configuration for sensitive data
#
# Provides transparent encryption/decryption for encrypted attributes
# such as passwords and PLC tokens

require 'lockbox'

# Set up Lockbox master key from environment
# Lockbox will automatically use this for encrypting attributes
if ENV['LOCKBOX_MASTER_KEY'].present?
  # Use dedicated Lockbox master key if provided (already in correct format)
  # LOCKBOX_MASTER_KEY should be 32 bytes hex-encoded (64 hex chars)
  ENV['LOCKBOX_MASTER_KEY']
elsif ENV['SECRET_KEY_BASE'].present?
  # Derive a Lockbox key from Rails SECRET_KEY_BASE
  # SECRET_KEY_BASE is hex-encoded, so we need 64 hex chars = 32 bytes
  # Lockbox expects the key in hex format
  ENV['LOCKBOX_MASTER_KEY'] = ENV['SECRET_KEY_BASE'][0, 64]
elsif Rails.env.test?
  # Test environment fallback - generate a deterministic key for testing
  require 'digest/sha2'
  ENV['LOCKBOX_MASTER_KEY'] = Digest::SHA256.hexdigest('test_lockbox_master_key')
elsif !Rails.env.production?
  # Development fallback - generate a warning key
  require 'digest/sha2'
  ENV['LOCKBOX_MASTER_KEY'] = Digest::SHA256.hexdigest('dev_lockbox_master_key')
  Rails.logger.warn("Lockbox: Using generated development key. Set LOCKBOX_MASTER_KEY for persistent encryption.")
else
  # Production requires explicit key
  raise "Lockbox encryption requires either LOCKBOX_MASTER_KEY or SECRET_KEY_BASE to be set"
end

Rails.logger.debug("Lockbox initialized for attribute encryption")
