# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DownloadAllDataJob, type: :job do
  let(:migration) do
    Migration.create!(
      email: "test@example.com",
      did: "did:plc:test123abc",
      old_handle: "test.old.bsky.social",
      old_pds_host: "https://old.pds.example",
      new_handle: "test.new.bsky.social",
      new_pds_host: "https://new.pds.example",
      status: :pending_download
    )
  end

  let(:goat_service) { instance_double(GoatService, migration: migration) }
  let(:blob_cids) { ['bafyabc123', 'bafydef456', 'bafyghi789'] }

  let(:storage_dir) { Rails.root.join('tmp', 'migrations', migration.did.gsub(/[^a-z0-9_-]/i, '_')) }

  before do
    allow(GoatService).to receive(:new).with(migration).and_return(goat_service)
  end

  after do
    FileUtils.rm_rf(storage_dir) if Dir.exist?(storage_dir)
  end

  describe '#perform' do
    context 'successful download' do
      let(:car_path) { Rails.root.join('tmp', 'test_repo.car') }

      before do
        # Create a fake CAR file for export_repo to return
        FileUtils.mkdir_p(File.dirname(car_path))
        File.write(car_path, "FAKE_CAR_DATA")

        allow(goat_service).to receive(:export_repo).and_return(car_path)
        allow(goat_service).to receive(:list_blobs).with(nil).and_return(
          { 'cids' => blob_cids, 'cursor' => nil }
        )

        # Stub Net::HTTP to simulate blob downloads
        stub_blob_downloads(blob_cids)
      end

      after do
        FileUtils.rm_f(car_path)
      end

      it 'advances to pending_backup status' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.status).to eq('pending_backup')
      end

      it 'creates storage directory' do
        described_class.perform_now(migration.id)

        expect(Dir.exist?(storage_dir)).to be true
      end

      it 'stores downloaded_data_path on migration' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.downloaded_data_path).to eq(storage_dir.to_s)
      end

      it 'copies repo.car to storage directory' do
        described_class.perform_now(migration.id)

        expect(File.exist?(storage_dir.join('repo.car'))).to be true
        expect(File.read(storage_dir.join('repo.car'))).to eq("FAKE_CAR_DATA")
      end

      it 'downloads all blobs to storage directory' do
        described_class.perform_now(migration.id)

        blob_cids.each do |cid|
          blob_path = storage_dir.join('blobs', cid)
          expect(File.exist?(blob_path)).to be true
        end
      end

      it 'records download progress' do
        described_class.perform_now(migration.id)

        migration.reload
        progress = migration.progress_data['download_progress']
        expect(progress['total']).to eq(blob_cids.length)
        expect(progress['downloaded']).to eq(blob_cids.length)
      end

      it 'enqueues CreateBackupBundleJob' do
        expect {
          described_class.perform_now(migration.id)
        }.to have_enqueued_job(CreateBackupBundleJob)
      end
    end

    context 'idempotency' do
      it 'skips if migration is already past pending_download' do
        migration.update!(status: :pending_backup)

        expect(goat_service).not_to receive(:export_repo)
        described_class.perform_now(migration.id)
      end
    end

    context 'with paginated blob listing' do
      let(:car_path) { Rails.root.join('tmp', 'test_repo.car') }

      before do
        FileUtils.mkdir_p(File.dirname(car_path))
        File.write(car_path, "FAKE_CAR")
        allow(goat_service).to receive(:export_repo).and_return(car_path)

        allow(goat_service).to receive(:list_blobs).with(nil).and_return(
          { 'cids' => ['blob1', 'blob2'], 'cursor' => 'page2' }
        )
        allow(goat_service).to receive(:list_blobs).with('page2').and_return(
          { 'cids' => ['blob3'], 'cursor' => nil }
        )

        stub_blob_downloads(['blob1', 'blob2', 'blob3'])
      end

      after do
        FileUtils.rm_f(car_path)
      end

      it 'fetches all pages' do
        expect(goat_service).to receive(:list_blobs).with(nil).ordered
        expect(goat_service).to receive(:list_blobs).with('page2').ordered

        described_class.perform_now(migration.id)
      end

      it 'downloads blobs from all pages' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.progress_data['download_progress']['total']).to eq(3)
      end
    end

    context 'with no blobs' do
      let(:car_path) { Rails.root.join('tmp', 'test_repo.car') }

      before do
        FileUtils.mkdir_p(File.dirname(car_path))
        File.write(car_path, "FAKE_CAR")
        allow(goat_service).to receive(:export_repo).and_return(car_path)
        allow(goat_service).to receive(:list_blobs).with(nil).and_return(
          { 'cids' => [], 'cursor' => nil }
        )
      end

      after do
        FileUtils.rm_f(car_path)
      end

      it 'completes successfully with zero blobs' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.status).to eq('pending_backup')
        expect(migration.progress_data['download_progress']['total']).to eq(0)
      end
    end

    context 'when download fails' do
      before do
        allow(goat_service).to receive(:export_repo).and_raise(
          GoatService::NetworkError, 'Connection refused'
        )
      end

      it 'marks migration as failed' do
        expect {
          described_class.perform_now(migration.id)
        }.to raise_error(GoatService::NetworkError)

        migration.reload
        expect(migration.status).to eq('failed')
        expect(migration.last_error).to include('Download failed')
      end
    end

    context 'with many concurrent migrations (no global limit)' do
      let(:car_path) { Rails.root.join('tmp', 'test_repo.car') }

      before do
        # Create 30 other migrations in heavy I/O states
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

        FileUtils.mkdir_p(File.dirname(car_path))
        File.write(car_path, "FAKE_CAR")
        allow(goat_service).to receive(:export_repo).and_return(car_path)
        allow(goat_service).to receive(:list_blobs).with(nil).and_return(
          { 'cids' => ['blob1'], 'cursor' => nil }
        )
        stub_blob_downloads(['blob1'])
      end

      after do
        FileUtils.rm_f(car_path)
      end

      it 'proceeds immediately without blocking' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.status).to eq('pending_backup')
      end

      it 'does not set queued state' do
        described_class.perform_now(migration.id)

        migration.reload
        expect(migration.progress_data).not_to have_key('queued')
      end
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
    it 'limits parallel blob downloads to 5' do
      expect(described_class::PARALLEL_BLOBS).to eq(5)
    end

    it 'defines progress update interval' do
      expect(described_class::PROGRESS_UPDATE_INTERVAL).to eq(10)
    end
  end

  private

  # Stub Net::HTTP requests to simulate blob downloads.
  # Creates a fake HTTP response that writes blob data to the file path.
  def stub_blob_downloads(cids)
    cids.each do |cid|
      stub_request(:get, "https://old.pds.example/xrpc/com.atproto.sync.getBlob?did=#{migration.did}&cid=#{cid}")
        .to_return(status: 200, body: "BLOB_DATA_#{cid}", headers: { 'Content-Type' => 'application/octet-stream' })
    end
  end
end
