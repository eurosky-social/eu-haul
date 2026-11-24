# frozen_string_literal: true

require 'rails_helper'

RSpec.describe RetryFailedBlobsJob, type: :job do
  let(:storage_dir) { Rails.root.join('tmp', 'migrations', 'test_retry') }
  let(:migration) do
    Migration.create!(
      email: "test@example.com",
      did: "did:plc:retry#{SecureRandom.hex(4)}",
      old_handle: "test.old.bsky.social",
      old_pds_host: "https://old.pds.example",
      new_handle: "test.new.bsky.social",
      new_pds_host: "https://new.pds.example",
      status: :pending_plc,
      downloaded_data_path: storage_dir.to_s,
      progress_data: { 'failed_blobs' => %w[bafya bafyb], 'blobs_completed' => 8, 'blobs_total' => 10 }
    )
  end
  let(:goat_service) { instance_double(GoatService) }

  before do
    allow(GoatService).to receive(:new).with(migration).and_return(goat_service)
    # Blob passes label their stats with the version the target PDS reports,
    # so the double has to answer for it.
    allow(goat_service).to receive(:target_pds_version).and_return('0.5.29')
    allow(goat_service).to receive(:login_new_pds)
    # The new PDS cannot say which files it lacks: every file is tried
    allow(goat_service).to receive(:missing_blob_cids).and_return(nil)
    allow_any_instance_of(described_class).to receive(:pause)
    FileUtils.mkdir_p(storage_dir.join('blobs'))
  end

  after do
    FileUtils.rm_rf(storage_dir) if Dir.exist?(storage_dir)
  end

  context 'when the blobs upload on retry' do
    before do
      File.write(storage_dir.join('blobs', 'bafya'), 'A')
      allow(goat_service).to receive(:download_blob).with('bafyb').and_return(storage_dir.join('dl-bafyb').to_s)
      File.write(storage_dir.join('dl-bafyb'), 'B')
      allow(goat_service).to receive(:upload_blob)
    end

    it 'prefers the backup-bundle copy, downloads the rest, and clears the list' do
      described_class.perform_now(migration.id, %w[bafya bafyb], 1)

      expect(goat_service).not_to have_received(:download_blob).with('bafya')
      expect(goat_service).to have_received(:upload_blob).with(storage_dir.join('blobs', 'bafya').to_s)
      expect(goat_service).to have_received(:upload_blob).with(storage_dir.join('dl-bafyb').to_s)

      progress = migration.reload.progress_data
      expect(progress['failed_blobs']).to eq([])
      expect(progress['blobs_completed']).to eq(10)
      expect(File.exist?(storage_dir.join('blobs', 'bafya'))).to be true
      expect(described_class).not_to have_been_enqueued
    end

    it 'sends no mail while the migration is not completed yet' do
      expect {
        described_class.perform_now(migration.id, %w[bafya bafyb], 1)
      }.not_to have_enqueued_mail(MigrationMailer, :blobs_transfer_complete)
    end

    it 'sends the FINAL mail once when the migration is completed' do
      migration.update!(status: :completed)

      expect {
        described_class.perform_now(migration.id, %w[bafya bafyb], 1)
      }.to have_enqueued_mail(MigrationMailer, :blobs_transfer_complete).once
      expect(migration.reload.progress_data['blobs_transfer_complete_mailed_at']).to be_present

      # a later manual retry with nothing left must not repeat it
      expect {
        described_class.perform_now(migration.id, [])
      }.not_to have_enqueued_mail(MigrationMailer, :blobs_transfer_complete)
    end
  end

  context 'when the blobs still fail' do
    before do
      allow(goat_service).to receive(:download_blob).and_return(storage_dir.join('dl').to_s)
      File.write(storage_dir.join('dl'), 'X')
      allow(goat_service).to receive(:upload_blob).and_raise(GoatService::NetworkError, '500 Internal Server Error')
    end

    it 'schedules the next background pass with the next delay' do
      described_class.perform_now(migration.id, %w[bafya bafyb], 1)

      expect(migration.reload.progress_data['failed_blobs']).to match_array(%w[bafya bafyb])
      expect(described_class).to have_been_enqueued.with(migration.id, match_array(%w[bafya bafyb]), 2)
    end

    it 'stops after the last background pass and records that it gave up' do
      described_class.perform_now(migration.id, %w[bafya bafyb], described_class::AUTO_RETRY_DELAYS.length + 1)

      expect(described_class).not_to have_been_enqueued
      expect(migration.reload.progress_data['blobs_auto_retry_exhausted_at']).to be_present
    end

    it 'sends the incomplete-transfer mail when it gives up on a completed migration' do
      migration.update!(status: :completed)

      expect {
        described_class.perform_now(migration.id, %w[bafya bafyb], described_class::AUTO_RETRY_DELAYS.length + 1)
      }.to have_enqueued_mail(MigrationMailer, :blobs_transfer_incomplete).once
    end

    it 'sends no incomplete mail while the migration is still in progress' do
      expect {
        described_class.perform_now(migration.id, %w[bafya bafyb], described_class::AUTO_RETRY_DELAYS.length + 1)
      }.not_to have_enqueued_mail(MigrationMailer, :blobs_transfer_incomplete)
    end

    it 'does not chain background passes after a manual retry' do
      described_class.perform_now(migration.id, %w[bafya bafyb])

      expect(described_class).not_to have_been_enqueued
    end
  end

  # bsky.social takes 1,000 files per account per day. A pass that runs into
  # that waits for the reset instead of collecting refusals, and one that got
  # files in does not use up an automatic pass: a big account needs a pass a
  # day.
  describe "the new PDS's daily upload quota" do
    let(:reset_at) { 8.hours.from_now.change(usec: 0) }
    let(:retry_at) { reset_at + described_class::QUOTA_RESET_MARGIN }
    let(:last_pass) { described_class::AUTO_RETRY_DELAYS.length + 1 }
    let(:quota_error) do
      GoatService::QuotaExhaustedError.new('PDS rate limit exceeded while uploading blob: 429 Too Many Requests',
                                           reset_at: reset_at, limit: 1000, remaining: 0,
                                           http_status: 429, phase: :upload)
    end
    let(:file_a) { storage_dir.join('blobs', 'bafya').to_s }
    let(:file_b) { storage_dir.join('blobs', 'bafyb').to_s }

    before do
      File.write(file_a, 'A')
      File.write(file_b, 'B')
    end

    context 'when files got in before the refusal' do
      before do
        allow(goat_service).to receive(:upload_blob).with(file_a)
        allow(goat_service).to receive(:upload_blob).with(file_b).and_raise(quota_error)
      end

      it 'runs the same pass again at the reset' do
        described_class.perform_now(migration.id, %w[bafya bafyb], 1)

        expect(described_class).to have_been_enqueued.with(migration.id, ['bafyb'], 1).at(retry_at)
        progress = migration.reload.progress_data
        expect(progress['failed_blobs']).to eq(['bafyb'])
        expect(progress['blobs_quota_retry_at']).to eq(retry_at.utc.iso8601)
      end

      it 'does not give up after the last pass either' do
        described_class.perform_now(migration.id, %w[bafya bafyb], last_pass)

        expect(described_class).to have_been_enqueued.with(migration.id, ['bafyb'], last_pass).at(retry_at)
        expect(migration.reload.progress_data['blobs_auto_retry_exhausted_at']).to be_blank
      end

      it 'keeps the session of a completed migration until after that pass' do
        migration.set_new_pds_tokens!(access_token: 'new-access', refresh_token: 'new-refresh')
        migration.update!(status: :completed, credentials_expires_at: 1.hour.from_now)

        described_class.perform_now(migration.id, %w[bafya bafyb], last_pass)

        migration.reload
        expect(migration.new_refresh_token).to eq('new-refresh')
        expect(migration.credentials_expires_at).to be >= retry_at + Migration::RETRY_SESSION_LIFETIME - 1.second
      end

      it 'sends no mail' do
        migration.update!(status: :completed)

        expect {
          described_class.perform_now(migration.id, %w[bafya bafyb], last_pass)
        }.not_to have_enqueued_mail(MigrationMailer, :blobs_transfer_incomplete)
      end
    end

    context 'when the first file is refused' do
      before { allow(goat_service).to receive(:upload_blob).and_raise(quota_error) }

      it 'tries no further files' do
        described_class.perform_now(migration.id, %w[bafya bafyb], 1)

        expect(goat_service).to have_received(:upload_blob).once
        expect(migration.reload.progress_data['failed_blobs']).to match_array(%w[bafya bafyb])
      end

      it 'uses up a pass, scheduled for the reset' do
        described_class.perform_now(migration.id, %w[bafya bafyb], 1)

        expect(described_class).to have_been_enqueued.with(migration.id, %w[bafya bafyb], 2).at(retry_at)
      end

      it 'gives up after the last pass' do
        described_class.perform_now(migration.id, %w[bafya bafyb], last_pass)

        expect(described_class).not_to have_been_enqueued
        expect(migration.reload.progress_data['blobs_auto_retry_exhausted_at']).to be_present
      end

      it 'starts a chain at the reset after a manual retry when no pass is coming' do
        described_class.perform_now(migration.id, %w[bafya bafyb])

        expect(described_class).to have_been_enqueued.with(migration.id, %w[bafya bafyb], 1).at(retry_at)
      end

      it 'leaves a coming pass alone after a manual retry' do
        migration.merge_progress!('blobs_auto_retry_scheduled_at' => Time.current.iso8601)

        described_class.perform_now(migration.id, %w[bafya bafyb])

        expect(described_class).not_to have_been_enqueued
        expect(migration.reload.progress_data['blobs_quota_retry_at']).to eq(retry_at.utc.iso8601)
      end
    end

    # The old PDS refusing a download says nothing about the new PDS's quota.
    it 'treats a refused download as an ordinary failure' do
      FileUtils.rm_f(file_b)
      download_refusal = GoatService::QuotaExhaustedError.new('429', reset_at: reset_at, http_status: 429, phase: :download)
      allow(goat_service).to receive(:download_blob).with('bafyb').and_raise(download_refusal)
      allow(goat_service).to receive(:upload_blob)

      described_class.perform_now(migration.id, %w[bafyb bafya], 1)

      expect(goat_service).to have_received(:upload_blob).with(file_a)
      expect(described_class).to have_been_enqueued.with(migration.id, ['bafyb'], 2)
      expect(migration.reload.progress_data['blobs_quota_retry_at']).to be_nil
    end
  end

  # Space files the quota left behind go with the same passes: they count
  # against the same quota. They come from the copies kept by the spaces
  # stage, as the old session that could download them may be gone.
  describe 'space files left by the quota' do
    let(:space) { "at://#{migration.did}/space/com.example.forum/general" }
    let(:files_dir) { SpaceTransferService.files_dir(migration) }
    let(:kept) { files_dir.join('bafyspace1').to_s }
    let(:reset_at) { 8.hours.from_now.change(usec: 0) }
    let(:quota_error) do
      GoatService::QuotaExhaustedError.new('429', reset_at: reset_at, http_status: 429, phase: :upload)
    end

    before do
      FileUtils.mkdir_p(files_dir)
      File.write(kept, 'SPACE')
      File.write(storage_dir.join('blobs', 'bafya'), 'A')
      File.write(storage_dir.join('blobs', 'bafyb'), 'B')
      migration.merge_progress!('failed_space_blobs' => [{ 'space' => space, 'cid' => 'bafyspace1' }])
    end

    after { FileUtils.rm_rf(files_dir) }

    it 'uploads them with the public files and clears both lists' do
      allow(goat_service).to receive(:upload_blob)

      described_class.perform_now(migration.id, %w[bafya bafyb], 1)

      expect(goat_service).to have_received(:upload_blob).with(kept)
      progress = migration.reload.progress_data
      expect(progress['failed_blobs']).to eq([])
      expect(progress['failed_space_blobs']).to eq([])
      expect(File.exist?(kept)).to be(false)
    end

    it 'waits for the space files before the final mail' do
      migration.update!(status: :completed)
      allow(goat_service).to receive(:upload_blob)
      allow(goat_service).to receive(:upload_blob).with(kept).and_raise(GoatService::NetworkError, '500')

      expect {
        described_class.perform_now(migration.id, %w[bafya bafyb], 1)
      }.not_to have_enqueued_mail(MigrationMailer, :blobs_transfer_complete)
      expect(described_class).to have_been_enqueued.with(migration.id, [], 2)
    end

    it 'parks them with the public files when the quota runs out' do
      allow(goat_service).to receive(:upload_blob).and_raise(quota_error)

      described_class.perform_now(migration.id, %w[bafya bafyb], 1)

      expect(goat_service).to have_received(:upload_blob).once
      expect(described_class).to have_been_enqueued
        .with(migration.id, match_array(%w[bafya bafyb]), 2).at(reset_at + described_class::QUOTA_RESET_MARGIN)
      expect(migration.reload.progress_data['failed_space_blobs']).to eq([{ 'space' => space, 'cid' => 'bafyspace1' }])
      expect(File.exist?(kept)).to be(true)
    end

    it 'signs in for a completed migration with only space files missing' do
      migration.update!(status: :completed)
      migration.merge_progress!('failed_blobs' => [])
      allow(goat_service).to receive(:upload_blob)

      expect {
        described_class.perform_now(migration.id, [], 1)
      }.to have_enqueued_mail(MigrationMailer, :blobs_transfer_complete).once
      expect(goat_service).to have_received(:upload_blob).with(kept)
    end
  end

  # Every upload counts against the quota, also of a file the PDS has.
  it 'skips the files the new PDS already has' do
    File.write(storage_dir.join('blobs', 'bafyb'), 'B')
    allow(goat_service).to receive(:missing_blob_cids).and_return(Set['bafyb'])
    allow(goat_service).to receive(:upload_blob)

    described_class.perform_now(migration.id, %w[bafya bafyb], 1)

    expect(goat_service).to have_received(:upload_blob).once
    expect(goat_service).to have_received(:upload_blob).with(storage_dir.join('blobs', 'bafyb').to_s)
    progress = migration.reload.progress_data
    expect(progress['failed_blobs']).to eq([])
    expect(progress['blobs_completed']).to eq(10)
  end

  it 'does nothing for a failed or cancelled migration' do
    migration.update!(status: :failed, error_code: 'cancelled')

    expect(goat_service).not_to receive(:login_new_pds)
    described_class.perform_now(migration.id, %w[bafya bafyb], 1)
  end

  # ActivateAccountJob keeps the new-PDS session of a completed migration for
  # these passes; the chain drops it when it ends.
  describe 'the new-PDS session kept for the passes' do
    let(:last_pass) { described_class::AUTO_RETRY_DELAYS.length + 1 }

    before do
      migration.set_new_pds_tokens!(access_token: 'new-access', refresh_token: 'new-refresh')
      migration.update!(credentials_expires_at: Migration::RETRY_SESSION_LIFETIME.from_now)
      allow(goat_service).to receive(:download_blob).and_return(storage_dir.join('dl').to_s)
      File.write(storage_dir.join('dl'), 'X')
    end

    context 'when the passes move every file' do
      before { allow(goat_service).to receive(:upload_blob) }

      it 'clears the session of a completed migration' do
        migration.update!(status: :completed)

        described_class.perform_now(migration.id, %w[bafya bafyb], 1)

        expect(migration.reload.has_new_pds_tokens?).to be(false)
        expect(migration.credentials_expires_at).to be_nil
      end

      it 'keeps the credentials of a migration still in progress' do
        described_class.perform_now(migration.id, %w[bafya bafyb], 1)

        expect(migration.reload.new_refresh_token).to eq('new-refresh')
      end
    end

    context 'when files still fail' do
      before do
        allow(goat_service).to receive(:upload_blob).and_raise(GoatService::NetworkError, '500 Internal Server Error')
        migration.update!(status: :completed)
      end

      it 'keeps the session while another pass is scheduled' do
        described_class.perform_now(migration.id, %w[bafya bafyb], 1)

        expect(migration.reload.new_refresh_token).to eq('new-refresh')
      end

      it 'clears the session after the last pass gives up' do
        described_class.perform_now(migration.id, %w[bafya bafyb], last_pass)

        expect(migration.reload.has_new_pds_tokens?).to be(false)
      end
    end

    it 'does not sign in when a completed migration has no files missing' do
      migration.update!(status: :completed)
      migration.merge_progress!('failed_blobs' => [])

      expect(goat_service).not_to receive(:login_new_pds)
      described_class.perform_now(migration.id, %w[bafya bafyb], 2)
    end
  end
end
