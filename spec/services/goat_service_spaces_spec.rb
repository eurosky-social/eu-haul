# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GoatService, 'spaces' do
  let(:old_host) { 'https://old.pds.example' }
  let(:new_host) { 'https://new.pds.example' }
  let(:did) { "did:plc:spaces#{SecureRandom.hex(4)}" }
  let(:own_space) { "at://#{did}/space/com.example.forum/general" }
  let(:other_space) { 'at://did:plc:someoneelse/space/com.example.forum/main' }
  let(:migration) do
    Migration.create!(
      email: 'test@example.com',
      did: did,
      old_handle: 'test.old.example',
      old_pds_host: old_host,
      new_handle: 'test.new.example',
      new_pds_host: new_host,
      status: :pending_spaces
    )
  end
  let(:goat) { described_class.new(migration) }
  let(:old_client) { double('old PDS client', config: { 'access_token' => 'old-token' }) }
  let(:new_client) { double('new PDS client', config: { 'access_token' => 'new-token' }) }

  before do
    [old_client, new_client].each do |client|
      allow(client).to receive(:check_access)
      allow(client).to receive(:perform_token_refresh) { client.config['access_token'] += '-fresh' }
    end
    allow(goat).to receive(:old_pds_client).and_return(old_client)
    allow(goat).to receive(:new_pds_client).and_return(new_client)
  end

  after { FileUtils.rm_rf(goat.work_dir) }

  def xrpc(host, nsid)
    %r{\A#{Regexp.escape(host)}/xrpc/#{Regexp.escape(nsid)}(\?|\z)}
  end

  # json(spaces: [...]) or json({ error: 'X' }, status: 400)
  def json(body = nil, status: 200, **fields)
    { status: status, body: (body || fields).to_json, headers: { 'Content-Type' => 'application/json' } }
  end

  describe '#list_spaces' do
    it "pages through the account's spaces with its session" do
      stub_request(:get, "#{old_host}/xrpc/com.atproto.space.listSpaces?limit=100")
        .with(headers: { 'Authorization' => 'Bearer old-token' })
        .to_return(json(spaces: [{ space: own_space }], cursor: 'c1'))
      stub_request(:get, "#{old_host}/xrpc/com.atproto.space.listSpaces?limit=100&cursor=c1")
        .to_return(json(spaces: [{ space: other_space }]))

      expect(goat.list_spaces(:old).map { |s| s['space'] }).to eq([own_space, other_space])
    end

    it 'raises SpacesUnsupportedError when the PDS has no spaces' do
      stub_request(:get, xrpc(old_host, 'com.atproto.space.listSpaces'))
        .to_return(json({ error: 'MethodNotImplemented', message: 'Method Not Implemented' }, status: 501))

      expect { goat.list_spaces(:old) }.to raise_error(GoatService::SpacesUnsupportedError)
    end

    it 'renews an expired access token once and asks again' do
      stub_request(:get, xrpc(old_host, 'com.atproto.space.listSpaces'))
        .with(headers: { 'Authorization' => 'Bearer old-token' })
        .to_return(json({ error: 'ExpiredToken', message: 'Token has expired' }, status: 401))
      stub_request(:get, xrpc(old_host, 'com.atproto.space.listSpaces'))
        .with(headers: { 'Authorization' => 'Bearer old-token-fresh' })
        .to_return(json(spaces: []))

      expect(goat.list_spaces(:old)).to eq([])
      expect(old_client).to have_received(:perform_token_refresh).once
    end
  end

  describe '#list_spaces on a PDS without spaces' do
    # A reference PDS with no AppView configured, or another PDS
    # implementation, refuses the unknown method with a client error
    it 'treats a client error as no spaces support' do
      stub_request(:get, xrpc(old_host, 'com.atproto.space.listSpaces'))
        .to_return(json({ error: 'InvalidRequest', message: 'No service configured for com.atproto.space.listSpaces' }, status: 400))

      expect { goat.list_spaces(:old) }.to raise_error(GoatService::SpacesUnsupportedError)
    end

    it 'does not hide a server failure' do
      stub_request(:get, xrpc(old_host, 'com.atproto.space.listSpaces'))
        .to_return(json({ error: 'InternalServerError' }, status: 500))

      expect { goat.list_spaces(:old) }.to raise_error(GoatService::SpaceRequestError)
    end
  end

  describe 'importing into a PDS without spaces' do
    let(:archive) { goat.work_dir.join('meta.star').tap { |p| File.binwrite(p, 'STAR-ARCHIVE') } }

    it 'raises SpacesUnsupportedError' do
      stub_request(:post, "#{new_host}/xrpc/com.atproto.space.importSpaceMeta")
        .to_return(json({ error: 'MethodNotImplemented', message: 'Method Not Implemented' }, status: 501))

      expect { goat.import_space_meta(archive) }.to raise_error(GoatService::SpacesUnsupportedError)
    end
  end

  describe '#export_space_repo' do
    it "saves the account's repo in the space" do
      stub_request(:get, xrpc(old_host, 'com.atproto.space.getRepo'))
        .with(query: { space: own_space, repo: did }, headers: { 'Authorization' => 'Bearer old-token' })
        .to_return(status: 200, body: 'STAR-ARCHIVE', headers: { 'Content-Type' => GoatService::SPACE_ARCHIVE_TYPE })

      path = goat.export_space_repo(own_space)

      expect(File.binread(path)).to eq('STAR-ARCHIVE')
    end

    it 'returns nil when the account has no repo in the space' do
      stub_request(:get, xrpc(old_host, 'com.atproto.space.getRepo'))
        .to_return(json({ error: 'RepoNotFound', message: 'Repo not found' }, status: 400))

      expect(goat.export_space_repo(own_space)).to be_nil
    end
  end

  describe '#import_space_repo' do
    let(:archive) { goat.work_dir.join('repo.star').tap { |p| File.binwrite(p, 'STAR-ARCHIVE') } }

    it 'posts the archive to the new PDS' do
      stub = stub_request(:post, "#{new_host}/xrpc/com.atproto.space.importRepo")
             .with(body: 'STAR-ARCHIVE',
                   headers: { 'Content-Type' => GoatService::SPACE_ARCHIVE_TYPE, 'Authorization' => 'Bearer new-token' })
             .to_return(status: 200, body: '')

      goat.import_space_repo(archive)

      expect(stub).to have_been_requested
    end

    it 'raises SpaceImportRejectedError when the new PDS refuses the data' do
      stub_request(:post, "#{new_host}/xrpc/com.atproto.space.importRepo")
        .to_return(json({ error: 'InvalidRepoFile', message: 'record is not canonical DRISL' }, status: 400))

      expect { goat.import_space_repo(archive) }.to raise_error(GoatService::SpaceImportRejectedError, /InvalidRepoFile|DRISL/)
    end

    it 'raises a retryable error on a server failure' do
      stub_request(:post, "#{new_host}/xrpc/com.atproto.space.importRepo")
        .to_return(json({ error: 'InternalServerError' }, status: 500))

      expect { goat.import_space_repo(archive) }.to raise_error(GoatService::SpaceRequestError)
    end
  end

  describe '#list_space_blobs and #download_space_blob' do
    it 'lists and downloads the files of the account\'s repo in a space' do
      stub_request(:get, xrpc(old_host, 'com.atproto.space.listBlobs'))
        .with(query: { space: own_space, repo: did, limit: '1000' })
        .to_return(json(cids: %w[bafyone bafytwo]))
      stub_request(:get, xrpc(old_host, 'com.atproto.space.getBlob'))
        .with(query: { space: own_space, repo: did, cid: 'bafyone' })
        .to_return(status: 200, body: 'IMAGE', headers: { 'Content-Type' => 'image/png' })

      expect(goat.list_space_blobs(own_space)).to eq(%w[bafyone bafytwo])

      path = goat.download_space_blob(own_space, 'bafyone')
      expect(File.basename(path)).to eq('bafyone')
      expect(File.binread(path)).to eq('IMAGE')
    end
  end

  describe '.space_authority' do
    it 'reads the authority DID from a space reference' do
      expect(described_class.space_authority(own_space)).to eq(did)
      expect(described_class.space_authority('not a space')).to be_nil
    end
  end
end
