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

  after { FileUtils.rm_rf(tmp) }

  # Space files go through the same uploadBlob as the public ones, so
  # bsky.social's 1,000 a day counts them too. Retrying a file before the
  # reset only collects refusals.
  context "when the new PDS's daily upload quota runs out" do
    let(:quota_error) do
      GoatService::QuotaExhaustedError.new('429', reset_at: 8.hours.from_now, http_status: 429, phase: :upload)
    end

    before do
      allow(goat).to receive(:list_space_blobs).with(own_space).and_return(%w[bafyown1 bafyown2])
      allow(goat).to receive(:list_space_blobs).with(other_space).and_return(%w[bafyother1])
      allow(goat).to receive(:upload_blob).and_raise(quota_error)
    end

    it 'stops sending space files at the first refusal' do
      service.transfer([{ 'space' => own_space }, { 'space' => other_space }])

      expect(goat).to have_received(:upload_blob).once
      expect(goat).to have_received(:download_space_blob).once
    end

    it 'still moves every space repo and reports every file not sent' do
      result = service.transfer([{ 'space' => own_space }, { 'space' => other_space }])

      expect(result.repos).to eq(2)
      expect(result.failed_blobs).to contain_exactly(
        { 'space' => own_space, 'cid' => 'bafyown1' },
        { 'space' => own_space, 'cid' => 'bafyown2' },
        { 'space' => other_space, 'cid' => 'bafyother1' }
      )
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
