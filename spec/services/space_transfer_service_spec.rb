# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SpaceTransferService do
  let(:did) { "did:plc:transfer#{SecureRandom.hex(4)}" }
  let(:own_space) { "at://#{did}/space/com.example.forum/general" }
  let(:other_space) { 'at://did:plc:someoneelse/space/com.example.forum/main' }
  let(:migration) do
    Migration.create!(
      email: 'test@example.com',
      did: did,
      old_handle: 'test.old.example',
      old_pds_host: 'https://old.pds.example',
      new_handle: 'test.new.example',
      new_pds_host: 'https://new.pds.example',
      status: :pending_spaces
    )
  end
  let(:goat) { instance_double(GoatService) }
  let(:service) { described_class.new(migration, goat: goat) }
  let(:tmp) { Rails.root.join('tmp', 'spec_space_transfer', SecureRandom.hex(4)) }

  def file(name)
    FileUtils.mkdir_p(tmp)
    tmp.join(name).to_s.tap { |path| File.write(path, name) }
  end

  before do
    allow(service).to receive(:pause)
    allow(goat).to receive(:export_space_meta) { |ref| file("meta-#{ref.hash.abs}") }
    allow(goat).to receive(:import_space_meta)
    allow(goat).to receive(:export_space_repo) { |ref| file("repo-#{ref.hash.abs}") }
    allow(goat).to receive(:import_space_repo)
    allow(goat).to receive(:list_space_blobs).and_return([])
    allow(goat).to receive(:download_space_blob) { |_ref, cid| file(cid) }
    allow(goat).to receive(:upload_blob)
  end

  after do
    FileUtils.rm_rf(tmp)
    FileUtils.rm_rf(described_class.files_dir(migration))
  end

  # Space files go through the same uploadBlob as the public ones, so
  # bsky.social's 1,000 a day counts them too. Retrying a file before the
  # reset only collects refusals. The files wait for the pass at the reset,
  # which may run after the old session is gone, and only that session can
  # download a space file: so they are downloaded now and kept.
  context "when the new PDS's daily upload quota runs out" do
    let(:reset_at) { 8.hours.from_now.change(usec: 0) }
    let(:quota_error) do
      GoatService::QuotaExhaustedError.new('429', reset_at: reset_at, http_status: 429, phase: :upload)
    end
    let(:files_dir) { described_class.files_dir(migration) }

    before do
      allow(goat).to receive(:list_space_blobs).with(own_space).and_return(%w[bafyown1 bafyown2])
      allow(goat).to receive(:list_space_blobs).with(other_space).and_return(%w[bafyother1])
      allow(goat).to receive(:download_space_blob) do |_ref, cid|
        FileUtils.mkdir_p(files_dir)
        files_dir.join(cid).to_s.tap { |path| File.write(path, cid) }
      end
      allow(goat).to receive(:upload_blob).and_raise(quota_error)
    end

    after { FileUtils.rm_rf(files_dir) }

    it 'stops uploading space files at the first refusal' do
      service.transfer([{ 'space' => own_space }, { 'space' => other_space }])

      expect(goat).to have_received(:upload_blob).once
    end

    it 'keeps a copy of every space file not sent, the refused one included' do
      service.transfer([{ 'space' => own_space }, { 'space' => other_space }])

      expect(%w[bafyown1 bafyown2 bafyother1].map { |cid| File.file?(files_dir.join(cid)) }).to all(be(true))
    end

    it 'still moves every space repo, and reports every file not sent and the refusal' do
      result = service.transfer([{ 'space' => own_space }, { 'space' => other_space }])

      expect(result.repos).to eq(2)
      expect(result.failed_blobs).to contain_exactly(
        { 'space' => own_space, 'cid' => 'bafyown1' },
        { 'space' => own_space, 'cid' => 'bafyown2' },
        { 'space' => other_space, 'cid' => 'bafyother1' }
      )
      expect(result.quota_error).to eq(quota_error)
    end
  end

  # The re-sync before activation moves every space again. Uploading files
  # the new PDS already has would spend the quota on nothing.
  describe 'files already sent' do
    let(:files_dir) { described_class.files_dir(migration) }

    before do
      allow(goat).to receive(:list_space_blobs).with(own_space).and_return(%w[bafyown1 bafyown2])
    end

    after { FileUtils.rm_rf(files_dir) }

    it 'are not uploaded again by a later transfer' do
      described_class.new(migration, goat: goat).tap { |s| allow(s).to receive(:pause) }.transfer([{ 'space' => own_space }])
      result = service.transfer([{ 'space' => own_space }])

      expect(goat).to have_received(:upload_blob).twice
      expect(result.blobs).to eq(2)
      expect(result.failed_blobs).to be_empty
    end
  end

  describe '#send_left_over' do
    let(:files_dir) { described_class.files_dir(migration) }
    let(:entries) { [{ 'space' => own_space, 'cid' => 'bafykept' }, { 'space' => own_space, 'cid' => 'bafygone' }] }

    before do
      FileUtils.mkdir_p(files_dir)
      File.write(files_dir.join('bafykept'), 'KEPT')
    end

    after { FileUtils.rm_rf(files_dir) }

    it 'uploads the kept copies, downloads the rest while it can, and deletes what it sent' do
      still, quota = service.send_left_over(entries)

      expect(goat).to have_received(:upload_blob).with(files_dir.join('bafykept').to_s)
      expect(goat).to have_received(:download_space_blob).with(own_space, 'bafygone')
      expect(still).to be_empty
      expect(quota).to be_nil
      expect(File.exist?(files_dir.join('bafykept'))).to be(false)
    end

    it 'keeps a file it cannot get, for a later pass' do
      allow(goat).to receive(:download_space_blob).and_raise(GoatService::AuthenticationError, 'old session gone')

      still, = service.send_left_over(entries)

      expect(still).to eq([{ 'space' => own_space, 'cid' => 'bafygone' }])
    end

    it 'stops at the quota and keeps the copies' do
      quota_error = GoatService::QuotaExhaustedError.new('429', reset_at: 8.hours.from_now, http_status: 429, phase: :upload)
      allow(goat).to receive(:upload_blob).and_raise(quota_error)

      still, quota = service.send_left_over(entries)

      expect(goat).to have_received(:upload_blob).once
      expect(still).to eq(entries)
      expect(quota).to eq(quota_error)
      expect(File.exist?(files_dir.join('bafykept'))).to be(true)
    end
  end

  it 'does nothing without spaces' do
    result = service.transfer([])

    expect(result.spaces).to eq(0)
    expect(goat).not_to have_received(:export_space_repo)
  end

  it "moves the settings of the account's own spaces before any repo" do
    calls = []
    allow(goat).to receive(:import_space_meta) { calls << :meta }
    allow(goat).to receive(:import_space_repo) { calls << :repo }

    service.transfer([{ 'space' => other_space }, { 'space' => own_space }])

    expect(goat).to have_received(:export_space_meta).with(own_space).once
    expect(goat).not_to have_received(:export_space_meta).with(other_space)
    expect(calls).to eq(%i[meta repo repo])
  end

  it "uploads a space's files only after its repo is imported" do
    calls = []
    allow(goat).to receive(:import_space_repo) { calls << :repo }
    allow(goat).to receive(:list_space_blobs).with(own_space).and_return(%w[bafyone])
    allow(goat).to receive(:upload_blob) { calls << :blob }

    result = service.transfer([{ 'space' => own_space }])

    expect(calls).to eq(%i[repo blob])
    expect(result.repos).to eq(1)
    expect(result.blobs).to eq(1)
    expect(result.failed_blobs).to eq([])
  end

  it 'skips the files of a space the account has no repo in' do
    allow(goat).to receive(:export_space_repo).with(own_space).and_return(nil)

    result = service.transfer([{ 'space' => own_space }])

    expect(goat).not_to have_received(:import_space_repo)
    expect(goat).not_to have_received(:list_space_blobs)
    expect(result.repos).to eq(0)
  end

  it 'records a file that keeps failing and carries on with the next' do
    allow(goat).to receive(:list_space_blobs).with(own_space).and_return(%w[bafybad bafygood])
    allow(goat).to receive(:upload_blob) do |path|
      raise GoatService::NetworkError, '500 Internal Server Error' if File.basename(path) == 'bafybad'
    end

    result = service.transfer([{ 'space' => own_space }])

    expect(goat).to have_received(:download_space_blob).with(own_space, 'bafybad').exactly(described_class::BLOB_ATTEMPTS).times
    expect(result.blobs).to eq(1)
    expect(result.failed_blobs).to eq([{ 'space' => own_space, 'cid' => 'bafybad' }])
  end

  it 'lets a rejected import stop the transfer' do
    allow(goat).to receive(:import_space_repo).and_raise(GoatService::SpaceImportRejectedError, 'InvalidRepoFile')

    expect { service.transfer([{ 'space' => own_space }]) }.to raise_error(GoatService::SpaceImportRejectedError)
  end

  it 'removes the archives it downloaded' do
    paths = []
    allow(goat).to receive(:export_space_repo) { |ref| file("repo-#{ref.hash.abs}").tap { |p| paths << p } }

    service.transfer([{ 'space' => own_space }])

    expect(paths).not_to be_empty
    expect(paths.none? { |p| File.exist?(p) }).to be(true)
  end
end
