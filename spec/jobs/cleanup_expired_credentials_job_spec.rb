# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CleanupExpiredCredentialsJob, type: :job do
  def migration_with_new_pds_session(status:)
    Migration.create!(
      email: 'test@example.com',
      did: "did:plc:cleanup#{SecureRandom.hex(4)}",
      old_handle: 'test.old.bsky.social',
      old_pds_host: 'https://old.pds.example',
      new_handle: 'test.new.bsky.social',
      new_pds_host: 'https://new.pds.example',
      status: status
    ).tap do |m|
      m.set_new_pds_tokens!(access_token: 'new-access', refresh_token: 'new-refresh')
      m.update!(credentials_expires_at: 1.minute.ago)
    end
  end

  it 'clears the expired new-PDS session a completed migration kept for its file retries' do
    migration = migration_with_new_pds_session(status: :completed)

    described_class.perform_now

    migration.reload
    expect(migration.encrypted_new_access_token).to be_nil
    expect(migration.encrypted_new_refresh_token).to be_nil
  end

  it 'leaves the new-PDS session of a migration still in progress alone' do
    migration = migration_with_new_pds_session(status: :pending_plc)

    described_class.perform_now

    expect(migration.reload.encrypted_new_refresh_token).to be_present
  end
end
