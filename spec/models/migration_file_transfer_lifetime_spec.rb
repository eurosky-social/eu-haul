# frozen_string_literal: true

require 'rails_helper'

# A transfer to bsky.social sends at most 1,000 files a day, so the files of a
# big account can still be on their way days after the 24-hour backup, the
# 8-hour retry session and the 2-day record retention were meant to end.
RSpec.describe Migration, 'while files are still being sent' do
  let(:storage_dir) { Rails.root.join('tmp', 'migrations', "lifetime-#{SecureRandom.hex(4)}") }
  let!(:migration) do
    Migration.create!(
      email: 'test@example.com',
      did: "did:plc:lifetime#{SecureRandom.hex(4)}",
      old_handle: 'test.old.bsky.social',
      old_pds_host: 'https://old.pds.example',
      new_handle: 'test.new.bsky.social',
      new_pds_host: 'https://bsky.social',
      status: :completed,
      downloaded_data_path: storage_dir.to_s,
      backup_expires_at: 1.hour.ago,
      progress_data: { 'failed_blobs' => %w[bafya bafyb],
                       'blobs_auto_retry_scheduled_at' => Time.current.iso8601 }
    )
  end

  before { FileUtils.mkdir_p(storage_dir.join('blobs')) }
  after { FileUtils.rm_rf(storage_dir) }

  describe '#files_still_transferring?' do
    it 'is true while a pass is coming for missing files' do
      expect(migration.files_still_transferring?).to be(true)
    end

    it 'is false once the automatic passes gave up' do
      migration.merge_progress!('blobs_auto_retry_exhausted_at' => Time.current.iso8601)

      expect(migration.files_still_transferring?).to be(false)
    end

    it 'is false once every file is in' do
      migration.merge_progress!('failed_blobs' => [])

      expect(migration.files_still_transferring?).to be(false)
    end

    it 'is true while a pass waits for the upload quota, however far ahead' do
      migration.merge_progress!('blobs_auto_retry_scheduled_at' => 2.days.ago.iso8601,
                                'blobs_quota_retry_at' => 3.hours.from_now.iso8601)

      expect(migration.files_still_transferring?).to be(true)
    end

    # A pass that kept crashing until Sidekiq gave up never records the end.
    it 'is false a day after a pass that never came was due' do
      migration.merge_progress!('blobs_auto_retry_scheduled_at' => (RetryFailedBlobsJob::AUTO_RETRY_DELAYS.max + 25.hours).ago.iso8601)

      expect(migration.files_still_transferring?).to be(false)
    end

    it 'is true during the file stage' do
      migration.update!(status: :pending_blobs, progress_data: {})

      expect(migration.files_still_transferring?).to be(true)
    end

    it 'is false for a failed or cancelled migration' do
      migration.update!(status: :failed)

      expect(migration.files_still_transferring?).to be(false)
    end
  end

  describe '#clear_credentials! keeping the new-PDS session' do
    it 'keeps it until after a pass waiting for the upload quota' do
      retry_at = 20.hours.from_now.change(usec: 0)
      migration.merge_progress!('blobs_quota_retry_at' => retry_at.utc.iso8601)

      migration.clear_credentials!(keep_new_pds_session: true)

      expect(migration.reload.credentials_expires_at).to be_within(1.second).of(retry_at + Migration::RETRY_SESSION_LIFETIME)
    end

    # Another job may park the files after this copy of the record was loaded.
    it 'reads the waiting pass from the database' do
      stale = Migration.find(migration.id)
      retry_at = 20.hours.from_now.change(usec: 0)
      migration.merge_progress!('blobs_quota_retry_at' => retry_at.utc.iso8601)

      stale.clear_credentials!(keep_new_pds_session: true)

      expect(stale.reload.credentials_expires_at).to be_within(1.second).of(retry_at + Migration::RETRY_SESSION_LIFETIME)
    end

    it 'keeps it for RETRY_SESSION_LIFETIME otherwise' do
      migration.clear_credentials!(keep_new_pds_session: true)

      expect(migration.reload.credentials_expires_at).to be_within(5.seconds).of(Migration::RETRY_SESSION_LIFETIME.from_now)
    end
  end

  describe CleanupBackupBundleJob do
    it 'keeps the local copies a coming pass uploads from' do
      CleanupBackupBundleJob.perform_now

      expect(migration.reload.downloaded_data_path).to eq(storage_dir.to_s)
      expect(Dir.exist?(storage_dir)).to be(true)
    end

    it 'deletes them once the passes are over' do
      migration.merge_progress!('blobs_auto_retry_exhausted_at' => Time.current.iso8601)

      CleanupBackupBundleJob.perform_now

      expect(migration.reload.downloaded_data_path).to be_nil
      expect(Dir.exist?(storage_dir)).to be(false)
    end
  end

  describe DeleteMigrationJob do
    it 'postpones deleting the record while files are still being sent' do
      DeleteMigrationJob.perform_now(migration.id)

      expect(Migration.exists?(migration.id)).to be(true)
      expect(DeleteMigrationJob).to have_been_enqueued.with(migration.id)
        .at(a_value_within(5.seconds).of(DeleteMigrationJob::POSTPONE_WHILE_TRANSFERRING.from_now))
    end

    it 'deletes it once every file is in' do
      migration.merge_progress!('failed_blobs' => [])

      DeleteMigrationJob.perform_now(migration.id)

      expect(Migration.exists?(migration.id)).to be(false)
    end
  end
end
