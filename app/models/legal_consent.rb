class LegalConsent < ApplicationRecord
  # Encryption for IP address using Lockbox (same key pattern as Migration model)
  lockbox_key = lambda do
    key_hex = ENV.fetch('LOCKBOX_MASTER_KEY') { Digest::SHA256.hexdigest('fallback_key_for_dev') }
    [key_hex].pack('H*')
  end

  has_encrypted :ip_address, key: lockbox_key, encrypted_attribute: :ip_address_ciphertext

  belongs_to :tos_snapshot, class_name: 'LegalSnapshot'
  belongs_to :privacy_policy_snapshot, class_name: 'LegalSnapshot'

  validates :did, presence: true
  validates :accepted_at, presence: true

  scope :for_did, ->(did) { where(did: did) }
end
