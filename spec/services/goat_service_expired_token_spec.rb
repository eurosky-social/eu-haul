# frozen_string_literal: true

require 'rails_helper'

# Moving a large account's files takes longer than an access token lives (two
# hours on the reference PDS). The PDS rejects an expired token with
# 400 ExpiredToken, not 401, and the file transfer only ever refreshed on 401.
# So once the token ran out, every remaining file failed, and so did every
# later retry pass, because it reused the same dead token.
RSpec.describe GoatService, 'access tokens during long file transfers' do
  let(:migration) do
    Migration.create!(
      email: 'test@example.com',
      did: 'did:plc:test123abc',
      old_handle: 'test.old.bsky.social',
      old_pds_host: 'https://old.pds.example',
      new_handle: 'test.new.bsky.social',
      new_pds_host: 'https://new.pds.example',
      status: 'pending_blobs'
    )
  end

  let(:service) { described_class.new(migration) }
  let(:cid) { 'bafkreiexpiredtokentest' }
  let(:upload_url) { "#{migration.new_pds_host}/xrpc/com.atproto.repo.uploadBlob" }
  let(:download_url) { "#{migration.old_pds_host}/xrpc/com.atproto.sync.getBlob?did=#{migration.did}&cid=#{cid}" }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:first_token) { fake_jwt(expires_at: 2.hours.from_now) }
  let(:expired) { { status: 400, headers: json, body: { error: 'ExpiredToken', message: 'Token has expired' }.to_json } }
  let(:uploaded) { { status: 200, headers: json, body: { blob: { ref: { '$link' => cid } } }.to_json } }

  before do
    migration.set_password('test_password_123', expires_in: 48.hours)
    migration.set_old_pds_tokens!(access_token: first_token, refresh_token: fake_jwt(expires_at: 30.days.from_now))
    migration.set_new_pds_tokens!(access_token: first_token, refresh_token: fake_jwt(expires_at: 30.days.from_now))
    stub_refresh_session(migration.old_pds_host)
    stub_refresh_session(migration.new_pds_host)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:debug)
    allow(Rails.logger).to receive(:warn)
    allow(Rails.logger).to receive(:error)
    allow(service).to receive(:sleep)
  end

  # The refreshed token is minted when the request arrives, so it is still
  # valid after a test has travelled forward in time. Its lifetime differs
  # from first_token's, so the two never come out as the same string.
  def stub_refresh_session(host)
    stub_request(:post, "#{host}/xrpc/com.atproto.server.refreshSession").to_return do
      { status: 200, headers: json, body: {
        did: migration.did, handle: migration.old_handle,
        accessJwt: fake_jwt(expires_at: 100.minutes.from_now),
        refreshJwt: fake_jwt(expires_at: 30.days.from_now)
      }.to_json }
    end
  end

  def sent_first_token?(request)
    request.headers['Authorization'] == "Bearer #{first_token}"
  end

  describe '#upload_blob' do
    let(:blob_path) { service.work_dir.join(cid) }

    before do
      FileUtils.mkdir_p(service.work_dir)
      File.write(blob_path, 'BINARY_BLOB_DATA')
    end

    after { FileUtils.rm_f(blob_path) }

    it 'refreshes the token once it has run out, instead of sending the dead one' do
      service.login_new_pds
      travel 3.hours
      stub_request(:post, upload_url).to_return { |request| sent_first_token?(request) ? expired : uploaded }

      expect(service.upload_blob(blob_path).dig('blob', 'ref', '$link')).to eq(cid)
      expect(a_request(:post, upload_url).with { |request| sent_first_token?(request) }).not_to have_been_made
    end

    it 'refreshes and retries once when the PDS answers 400 ExpiredToken to a token that looked valid' do
      service.login_new_pds
      stub_request(:post, upload_url).to_return { |request| sent_first_token?(request) ? expired : uploaded }

      expect(service.upload_blob(blob_path).dig('blob', 'ref', '$link')).to eq(cid)
      expect(a_request(:post, upload_url)).to have_been_made.twice
    end

    it 'gives up after one refresh when the PDS keeps answering ExpiredToken' do
      service.login_new_pds
      stub_request(:post, upload_url).to_return(expired)

      expect { service.upload_blob(blob_path) }.to raise_error(GoatService::NetworkError) { |error|
        expect(error.http_status).to eq(400)
        expect(error.body_snippet).to include('ExpiredToken')
      }
      expect(a_request(:post, upload_url)).to have_been_made.twice
    end

    it 'gives up after one refresh when the PDS keeps answering 401' do
      service.login_new_pds
      stub_request(:post, upload_url).to_return(status: 401, headers: json,
                                                body: { error: 'AuthenticationRequired' }.to_json)

      expect { service.upload_blob(blob_path) }.to raise_error(GoatService::NetworkError) { |error|
        expect(error.http_status).to eq(401)
      }
      expect(a_request(:post, upload_url)).to have_been_made.twice
    end
  end

  describe '#download_blob' do
    after { FileUtils.rm_f(service.work_dir.join('blobs', cid)) }

    it 'refreshes the old-PDS token before reading a file after it has run out' do
      service.login_old_pds
      travel 3.hours
      stub_request(:get, download_url)
        .to_return { |request| sent_first_token?(request) ? expired : { status: 200, body: 'BLOB' } }

      expect(File.read(service.download_blob(cid))).to eq('BLOB')
      expect(a_request(:get, download_url).with { |request| sent_first_token?(request) }).not_to have_been_made
    end

    it 'refreshes and retries once when the old PDS answers 400 ExpiredToken' do
      service.login_old_pds
      stub_request(:get, download_url)
        .to_return { |request| sent_first_token?(request) ? expired : { status: 200, body: 'BLOB' } }

      expect(File.read(service.download_blob(cid))).to eq('BLOB')
      expect(a_request(:get, download_url)).to have_been_made.twice
    end
  end
end
