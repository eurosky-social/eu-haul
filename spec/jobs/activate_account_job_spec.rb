# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActivateAccountJob, type: :job do
  let(:failed_blobs) { [] }
  let(:migration) do
    Migration.create!(
      email: 'test@example.com',
      did: "did:plc:activate#{SecureRandom.hex(4)}",
      old_handle: 'test.old.bsky.social',
      old_pds_host: 'https://old.pds.example',
      new_handle: 'test.new.bsky.social',
      new_pds_host: 'https://new.pds.example',
      status: :pending_activation,
      progress_data: { 'failed_blobs' => failed_blobs, 'blobs_completed' => 8, 'blobs_total' => 10 }
    ).tap do |m|
      m.set_password('new-account-password')
      m.set_old_pds_tokens!(access_token: 'old-access', refresh_token: 'old-refresh')
      m.set_new_pds_tokens!(access_token: 'new-access', refresh_token: 'new-refresh')
      m.set_plc_token('plc-token')
    end
  end
  let(:goat_service) { instance_double(GoatService, activate_account: true, deactivate_account: true) }

  before do
    allow(GoatService).to receive(:new).with(migration).and_return(goat_service)
    allow(GoatService).to receive(:same_pds_by_address?).and_return(false)
  end

  context 'when every file was transferred' do
    it 'completes the migration and clears all credentials' do
      described_class.perform_now(migration.id)

      migration.reload
      expect(migration).to be_completed
      expect(migration.encrypted_password).to be_nil
      expect(migration.encrypted_plc_token).to be_nil
      expect(migration.encrypted_old_refresh_token).to be_nil
      expect(migration.encrypted_new_access_token).to be_nil
      expect(migration.encrypted_new_refresh_token).to be_nil
      expect(RetryFailedBlobsJob).not_to have_been_enqueued
    end
  end

  context 'when files are still missing at completion' do
    let(:failed_blobs) { %w[bafya bafyb] }

    it 'schedules the background retry' do
      described_class.perform_now(migration.id)

      expect(RetryFailedBlobsJob).to have_been_enqueued.with(migration.id, %w[bafya bafyb], 1)
    end

    # The retry signs in to the new PDS with the stored session. Clearing it
    # at completion left the retry unable to upload anything.
    it 'keeps the new-PDS session the retry signs in with' do
      described_class.perform_now(migration.id)

      migration.reload
      expect(migration).to be_completed
      expect(migration.has_new_pds_tokens?).to be(true)
      expect(migration.new_refresh_token).to eq('new-refresh')
      expect(migration.new_access_token).to eq('new-access')
    end

    it 'keeps the session only for as long as the retry passes need it' do
      described_class.perform_now(migration.id)

      expect(migration.reload.credentials_expires_at)
        .to be_within(1.minute).of(Migration::RETRY_SESSION_LIFETIME.from_now)
    end

    it 'still clears everything else' do
      described_class.perform_now(migration.id)

      migration.reload
      expect(migration.encrypted_password).to be_nil
      expect(migration.encrypted_plc_token).to be_nil
      expect(migration.encrypted_old_access_token).to be_nil
      expect(migration.encrypted_old_refresh_token).to be_nil
    end

    context 'when a retry chain from the blob stage is still pending' do
      let(:migration) do
        super().tap { |m| m.merge_progress!('blobs_auto_retry_scheduled_at' => 1.minute.ago.iso8601) }
      end

      it 'schedules no second chain but keeps the session for the pending one' do
        described_class.perform_now(migration.id)

        expect(RetryFailedBlobsJob).not_to have_been_enqueued
        expect(migration.reload.new_refresh_token).to eq('new-refresh')
      end
    end
  end

  # Members kept writing to the account's spaces on the old PDS while the
  # migration ran; activation moves them once more first.
  # Space files count as missing files: the passes that send them sign in
  # with the new-PDS session.
  context 'when only space files are missing at completion' do
    before do
      migration.merge_progress!('failed_space_blobs' => [{ 'space' => 'at://x/space/a/b', 'cid' => 'bafys' }])
    end

    it 'keeps the new-PDS session and schedules the background retry' do
      described_class.perform_now(migration.id)

      expect(migration.reload.new_refresh_token).to eq('new-refresh')
      expect(RetryFailedBlobsJob).to have_been_enqueued.with(migration.id, [], 1)
    end
  end

  describe 're-syncing spaces before activation' do
    let(:space) { "at://#{migration.did}/space/com.example.forum/general" }
    let(:transfer) { instance_double(SpaceTransferService) }
    let(:calls) { [] }

    before do
      migration.merge_progress!('spaces_total' => 1)
      allow(SpaceTransferService).to receive(:new).with(migration, goat: goat_service).and_return(transfer)
      allow(goat_service).to receive(:list_spaces).with(:old).and_return([{ 'space' => space }])
      allow(goat_service).to receive(:activate_account) { calls << :activate }
    end

    it 'moves the spaces again before activating the account' do
      allow(transfer).to receive(:transfer) do
        calls << :spaces
        SpaceTransferService::Result.new(spaces: 1, repos: 1, blobs: 3, failed_blobs: [])
      end

      described_class.perform_now(migration.id)

      expect(calls).to eq(%i[spaces activate])
      progress = migration.reload.progress_data
      expect(progress['space_blobs_moved']).to eq(3)
      expect(progress['spaces_resynced_at']).to be_present
    end

    it 'schedules a pass for the space files the quota stopped' do
      reset_at = 8.hours.from_now.change(usec: 0)
      quota_error = GoatService::QuotaExhaustedError.new('429', reset_at: reset_at, http_status: 429, phase: :upload)
      allow(transfer).to receive(:transfer).and_return(
        SpaceTransferService::Result.new(spaces: 1, repos: 1, blobs: 0,
                                         failed_blobs: [{ 'space' => space, 'cid' => 'bafys' }], quota_error: quota_error)
      )

      described_class.perform_now(migration.id)

      expect(RetryFailedBlobsJob).to have_been_enqueued.with(migration.id, [], 1)
        .at(reset_at + RetryFailedBlobsJob::QUOTA_RESET_MARGIN)
      expect(RetryFailedBlobsJob).not_to have_been_enqueued.with(migration.id, [], 1).at(a_value_within(1.minute).of(15.minutes.from_now))
    end

    it 'still activates the account when the re-sync fails' do
      allow(transfer).to receive(:transfer).and_raise(GoatService::SpaceRequestError, '500 Internal Server Error')

      described_class.perform_now(migration.id)

      migration.reload
      expect(migration).to be_completed
      expect(migration.progress_data['spaces_resync_error']).to include('500')
    end
  end
end
