# frozen_string_literal: true

require 'rails_helper'

RSpec.describe UploadBlobsJob, type: :job do
  let(:storage_dir) { Rails.root.join('tmp', 'migrations', 'test_upload') }
  let(:blobs_dir) { storage_dir.join('blobs') }

  let(:migration) do
    Migration.create!(
      email: "test@example.com",
      did: "did:plc:test123abc",
      old_handle: "test.old.bsky.social",
      old_pds_host: "https://old.pds.example",
      new_handle: "test.new.bsky.social",
      new_pds_host: "https://new.pds.example",
      status: :pending_blobs,
      downloaded_data_path: storage_dir.to_s
    )
  end

  after { BlobTransferStat.delete_all }

  let(:goat_service) { instance_double(GoatService) }
  let(:blob_cids) { ['bafyabc123', 'bafydef456', 'bafyghi789'] }

  before do
    allow(GoatService).to receive(:new).with(migration).and_return(goat_service)
    # Blob passes label their stats with the version the target PDS reports,
    # so the double has to answer for it.
    allow(goat_service).to receive(:target_pds_version).and_return('0.5.29')
    allow(goat_service).to receive(:login_new_pds)
    # The new PDS cannot say which files it lacks: every file is sent
    allow(goat_service).to receive(:missing_blob_cids).and_return(nil)
    # Skip retry backoffs and the second-pass breather
    allow_any_instance_of(described_class).to receive(:pause)

    # Create local blob files
    FileUtils.mkdir_p(blobs_dir)
    blob_cids.each do |cid|
      File.write(blobs_dir.join(cid), "BLOB_DATA_#{cid}")
    end
  end

  after do
    FileUtils.rm_rf(storage_dir) if Dir.exist?(storage_dir)
  end

  describe '#perform' do
    context 'successful upload' do
      before do
        blob_cids.each do |cid|
          allow(goat_service).to receive(:upload_blob).with(blobs_dir.join(cid).to_s)
        end
      end

      it 'advances to pending_prefs status' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.status).to eq('pending_prefs')
      end

      it 'records progress under the keys the status page reads' do
        described_class.perform_now(migration.id)

        progress = migration.reload.progress_data
        expect(progress['blobs_completed']).to eq(3)
        expect(progress['blobs_total']).to eq(3)
        expect(progress['bytes_transferred']).to be > 0
      end

      it 'logs in to new PDS' do
        expect(goat_service).to receive(:login_new_pds)
        described_class.perform_now(migration.id)
      end

      it 'uploads each local blob' do
        blob_cids.each do |cid|
          expect(goat_service).to receive(:upload_blob).with(blobs_dir.join(cid).to_s)
        end

        described_class.perform_now(migration.id)
      end

      # The durable record of the pass: the log line rotates away, this does not.
      it 'records a blob transfer stat for the pass' do
        described_class.perform_now(migration.id)

        stat = BlobTransferStat.find_by(migration_id: migration.id, pass: 'parallel')
        expect(stat).to have_attributes(
          job_name: 'UploadBlobsJob',
          target_pds_version: '0.5.29',
          blobs_attempted: blob_cids.length,
          blobs_succeeded: blob_cids.length,
          blobs_failed: 0
        )
        expect(stat.bytes_transferred).to be > 0
      end

      it 'tracks upload progress' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.progress_data['blobs_uploaded']).to eq(blob_cids.length)
        expect(migration.progress_data['blobs_total']).to eq(blob_cids.length)
      end

      it 'enqueues ImportPrefsJob' do
        expect {
          described_class.perform_now(migration.id)
        }.to have_enqueued_job(ImportPrefsJob)
      end
    end

    context 'idempotency' do
      it 'skips if migration is already past pending_blobs' do
        migration.update!(status: :pending_prefs)

        expect(goat_service).not_to receive(:login_new_pds)
        described_class.perform_now(migration.id)
      end
    end

    context 'when downloaded_data_path is not set' do
      before do
        migration.update_columns(downloaded_data_path: nil)
      end

      it 'raises an error' do
        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(RuntimeError, /Downloaded data path not set/)
      end

      it 'marks migration as failed' do
        described_class.perform_now(migration.id) rescue nil

        migration.reload
        expect(migration.status).to eq('failed')
      end
    end

    context 'when blobs directory does not exist' do
      before do
        FileUtils.rm_rf(blobs_dir)
      end

      it 'raises an error' do
        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(RuntimeError, /Blobs directory not found/)
      end
    end

    context 'with no blob files' do
      before do
        # Remove all blob files, leave directory empty
        blob_cids.each { |cid| FileUtils.rm_f(blobs_dir.join(cid)) }
      end

      it 'completes successfully with zero blobs' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.status).to eq('pending_prefs')
        expect(migration.progress_data['blobs_total']).to eq(0)
      end
    end

    context 'when upload fails' do
      before do
        blob_cids.each do |cid|
          allow(goat_service).to receive(:upload_blob).with(blobs_dir.join(cid).to_s)
            .and_raise(GoatService::NetworkError, 'Upload failed')
        end
      end

      it 'records failed blobs but does not fail the job' do
        # Individual blob failures are caught and logged, not re-raised
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.progress_data['failed_uploads']).to be_present
        expect(migration.progress_data['failed_uploads'].length).to eq(blob_cids.length)
      end

      it 'exposes the failures under the key the status page and retry use' do
        described_class.perform_now(migration.id)

        expect(migration.reload.progress_data['failed_blobs']).to match_array(blob_cids)
      end

      it 'schedules an automatic retry of the leftovers' do
        described_class.perform_now(migration.id)

        expect(RetryFailedBlobsJob).to have_been_enqueued.with(migration.id, match_array(blob_cids), 1)
      end

      it 'retries the leftovers sequentially after the parallel pass' do
        calls = Hash.new(0)
        allow(goat_service).to receive(:upload_blob) do |path|
          calls[path] += 1
          # fail the parallel pass (5 attempts) and the first sequential attempt, then succeed
          raise GoatService::NetworkError, 'Upload failed' if calls[path] <= 6
        end

        described_class.perform_now(migration.id)

        progress = migration.reload.progress_data
        expect(progress['failed_blobs']).to be_blank
        expect(progress['blobs_completed']).to eq(blob_cids.length)
        expect(migration.status).to eq('pending_prefs')
      end
    end

    context 'with many concurrent migrations (no global limit)' do
      before do
        30.times do |i|
          Migration.create!(
            email: "concurrent#{i}@example.com",
            did: "did:plc:concurrent#{i}",
            old_handle: "test#{i}.old.bsky.social",
            old_pds_host: "https://old.pds.example",
            new_handle: "test#{i}.new.bsky.social",
            new_pds_host: "https://new.pds.example",
            status: [:pending_download, :pending_blobs].sample
          )
        end

        blob_cids.each do |cid|
          allow(goat_service).to receive(:upload_blob).with(blobs_dir.join(cid).to_s)
        end
      end

      it 'proceeds immediately without blocking' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.status).to eq('pending_prefs')
      end

      it 'does not set queued state' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.progress_data).not_to have_key('queued')
      end
    end
  end

  # Transfer 18790 (2026-11-21): bsky.social took 1,000 of the account's 3,022
  # files and then refused every upload until the next day. The stage kept
  # trying each file, gave up on all of them, retried them all once more in
  # the second pass and advanced with nothing scheduled for when the quota
  # came back.
  describe "when the new PDS's daily upload quota runs out" do
    let(:blob_cids) { Array.new(20) { |i| format('bafyquota%02d', i) } }
    let(:reset_at) { 8.hours.from_now.change(usec: 0) }
    let(:retry_at) { reset_at + RetryFailedBlobsJob::QUOTA_RESET_MARGIN }
    let(:quota_error) do
      GoatService::QuotaExhaustedError.new('PDS rate limit exceeded while uploading blob: 429 Too Many Requests',
                                           reset_at: reset_at, limit: 1000, remaining: 0,
                                           http_status: 429, phase: :upload)
    end
    let(:sent) { Queue.new }

    before do
      accepted = false
      lock = Mutex.new
      allow(goat_service).to receive(:upload_blob) do |path|
        sent << path
        first = lock.synchronize { !accepted && (accepted = true) }
        raise quota_error unless first
      end
    end

    it 'stops sending files once the PDS refuses them' do
      described_class.perform_now(migration.id)

      # Threads already uploading finish their file; nobody takes a new one.
      expect(sent.size).to be <= described_class::PARALLEL_BLOBS + 1
    end

    it 'keeps every file not sent for later' do
      described_class.perform_now(migration.id)

      progress = migration.reload.progress_data
      expect(progress['failed_blobs'].length).to eq(blob_cids.length - 1)
      expect(progress['blobs_completed']).to eq(1)
    end

    it 'schedules the next pass for when the quota comes back' do
      described_class.perform_now(migration.id)

      failed = migration.reload.progress_data['failed_blobs']
      expect(RetryFailedBlobsJob).to have_been_enqueued.with(migration.id, match_array(failed), 1).at(retry_at)
      expect(migration.progress_data).to include('blobs_quota_retry_at' => retry_at.utc.iso8601,
                                                 'blobs_quota_limit' => 1000)
    end

    it 'goes on with the migration' do
      described_class.perform_now(migration.id)

      expect(migration.reload.status).to eq('pending_prefs')
    end
  end

  context 'when the quota runs out during the second pass' do
    let(:reset_at) { 8.hours.from_now.change(usec: 0) }
    let(:calls) { Hash.new(0) }

    before do
      lock = Mutex.new
      allow(goat_service).to receive(:upload_blob) do |path|
        count = lock.synchronize { calls[path] += 1 }
        # every parallel attempt fails, then the first file of the second pass hits the quota
        raise GoatService::NetworkError, '500 Internal Server Error' if count <= described_class::MAX_RETRIES

        raise GoatService::QuotaExhaustedError.new('429', reset_at: reset_at, http_status: 429, phase: :upload)
      end
    end

    it 'leaves the rest for the pass at the reset' do
      described_class.perform_now(migration.id)

      expect(calls.values.sum).to eq(blob_cids.length * described_class::MAX_RETRIES + 1)
      expect(RetryFailedBlobsJob).to have_been_enqueued
        .with(migration.id, match_array(blob_cids), 1).at(reset_at + RetryFailedBlobsJob::QUOTA_RESET_MARGIN)
    end
  end

  # Every upload counts against the quota, also of a file the PDS has.
  context 'when the new PDS already has some of the files' do
    before do
      allow(goat_service).to receive(:missing_blob_cids).and_return(Set['bafydef456'])
      allow(goat_service).to receive(:upload_blob)
    end

    it 'uploads only the missing ones' do
      described_class.perform_now(migration.id)

      expect(goat_service).to have_received(:upload_blob).once
      expect(goat_service).to have_received(:upload_blob).with(blobs_dir.join('bafydef456').to_s)
    end

    it 'counts the others as done' do
      described_class.perform_now(migration.id)

      progress = migration.reload.progress_data
      expect(progress['blobs_completed']).to eq(3)
      expect(progress['blobs_total']).to eq(3)
      expect(progress['failed_blobs']).to be_nil
      expect(migration.status).to eq('pending_prefs')
    end
  end

  describe 'job configuration' do
    it 'is enqueued in migrations queue' do
      expect(described_class.new.queue_name).to eq('migrations')
    end

    it 'retries on StandardError' do
      expect(described_class.retry_on_block_for(StandardError)).to be_present
    end

    it 'retries on RateLimitError' do
      expect(described_class.retry_on_block_for(GoatService::RateLimitError)).to be_present
    end
  end

  describe 'constants' do
    it 'limits parallel blob uploads to 5' do
      expect(described_class::PARALLEL_BLOBS).to eq(5)
    end

    it 'defines progress update interval' do
      expect(described_class::PROGRESS_UPDATE_INTERVAL).to eq(10)
    end
  end
end
