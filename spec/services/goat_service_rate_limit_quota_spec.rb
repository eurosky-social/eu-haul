# frozen_string_literal: true

require 'rails_helper'

# bsky.social takes 1,000 uploadBlob calls per account per day. Past that it
# answers every upload with 429 and says in RateLimit-Reset (a Unix time) when
# the window ends, hours later. eu-haul read only Retry-After, which bsky.social
# does not send, so it retried each file four times within ~30 s, gave up on
# it and moved on to the next one: about 15 refused requests a minute for the
# rest of the day, and every file of a big account marked as failed.
RSpec.describe GoatService, 'rate limits and the daily upload quota' do
  let(:migration) do
    Migration.create!(
      email: 'test@example.com',
      did: 'did:plc:quota123abc',
      old_handle: 'test.old.bsky.social',
      old_pds_host: 'https://old.pds.example',
      new_handle: 'test.new.bsky.social',
      new_pds_host: 'https://new.pds.example',
      status: 'pending_blobs'
    )
  end

  let(:service) { described_class.new(migration) }
  let(:cid) { 'bafyreiquota123' }
  let(:blob_path) { service.work_dir.join(cid) }
  let(:upload_url) { "#{migration.new_pds_host}/xrpc/com.atproto.repo.uploadBlob" }
  let(:uploaded) do
    { status: 200, body: { blob: { ref: { '$link' => cid } } }.to_json,
      headers: { 'Content-Type' => 'application/json' } }
  end

  # What the reference PDS sends with a 429 from the uploadBlob limit
  # (xrpc-server setStatusHeaders): limit, 0 left, the window's end in Unix
  # seconds, and the policy. Retry-After only from 2026-07 on.
  def quota_refusal(reset_at:, retry_after: nil)
    headers = {
      'RateLimit-Limit' => '1000',
      'RateLimit-Remaining' => '0',
      'RateLimit-Reset' => reset_at.to_i.to_s,
      'RateLimit-Policy' => '1000;w=86400',
      'Content-Type' => 'application/json'
    }
    headers['Retry-After'] = retry_after.to_s if retry_after
    { status: 429, headers: headers,
      body: { error: 'RateLimitExceeded', message: 'Rate Limit Exceeded' }.to_json }
  end

  before do
    migration.set_password('test_password_123', expires_in: 48.hours)
    migration.set_old_pds_tokens!(access_token: fake_jwt,
                                  refresh_token: fake_jwt(expires_at: 30.days.from_now))
    stub_pds_sessions(migration)
    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:debug)
    allow(Rails.logger).to receive(:warn)
    allow(Rails.logger).to receive(:error)
    allow(service).to receive(:sleep)
    FileUtils.mkdir_p(service.work_dir)
    File.write(blob_path, 'BINARY_BLOB_DATA')
  end

  after { FileUtils.rm_f(blob_path) }

  describe '#upload_blob against a used-up daily quota' do
    let(:reset_at) { 8.hours.from_now.change(usec: 0) }

    before { stub_request(:post, upload_url).to_return(quota_refusal(reset_at: reset_at)) }

    it 'gives up on the first refusal instead of retrying' do
      expect { service.upload_blob(blob_path) }.to raise_error(GoatService::RateLimitError)

      expect(WebMock).to have_requested(:post, upload_url).once
      expect(service).not_to have_received(:sleep)
    end

    it 'says when the quota comes back' do
      expect { service.upload_blob(blob_path) }.to raise_error(GoatService::QuotaExhaustedError) { |error|
        expect(error.reset_at).to eq(reset_at)
        expect(error.limit).to eq(1000)
        expect(error.remaining).to eq(0)
        expect(error.http_status).to eq(429)
        expect(error.cid).to eq(cid)
      }
    end

    it 'counts as a rate-limit error for callers that rescue those' do
      expect(GoatService::QuotaExhaustedError.ancestors).to include(GoatService::RateLimitError)
    end

    it 'reads a long Retry-After the same way' do
      stub_request(:post, upload_url).to_return(status: 429, headers: { 'Retry-After' => '28800' }, body: '')

      expect { service.upload_blob(blob_path) }.to raise_error(GoatService::QuotaExhaustedError) { |error|
        expect(error.reset_at).to be_within(5.seconds).of(8.hours.from_now)
      }
      expect(WebMock).to have_requested(:post, upload_url).once
    end

    # RFC 9110 lets Retry-After be a date.
    it 'reads a Retry-After date' do
      stub_request(:post, upload_url)
        .to_return(status: 429, headers: { 'Retry-After' => reset_at.httpdate }, body: '')

      expect { service.upload_blob(blob_path) }.to raise_error(GoatService::QuotaExhaustedError) { |error|
        expect(error.reset_at).to eq(reset_at)
      }
    end

    # The IETF RateLimit header draft sends seconds left rather than a time.
    it 'reads a RateLimit-Reset given in seconds left' do
      stub_request(:post, upload_url)
        .to_return(status: 429, headers: { 'RateLimit-Remaining' => '0', 'RateLimit-Reset' => '28800' }, body: '')

      expect { service.upload_blob(blob_path) }.to raise_error(GoatService::QuotaExhaustedError) { |error|
        expect(error.reset_at).to be_within(5.seconds).of(8.hours.from_now)
      }
    end
  end

  describe '#upload_blob against a short limit' do
    it 'waits until the reset the PDS names, then uploads' do
      waits = []
      allow(service).to receive(:sleep) { |seconds| waits << seconds }
      stub_request(:post, upload_url)
        .to_return(quota_refusal(reset_at: 20.seconds.from_now))
        .then.to_return(uploaded)

      expect(service.upload_blob(blob_path)).to include('blob')

      expect(waits.length).to eq(1)
      expect(waits.first).to be_between(15, 20 * 1.25 + 1)
    end

    # Windows of a few minutes, such as bsky.social's 3,000 requests per IP per
    # 5 minutes, were waited out in place before and still are: only a reset
    # beyond what the retries add up to stops the transfer.
    it 'waits out a window of a couple of minutes in 60-second steps' do
      waits = []
      allow(service).to receive(:sleep) { |seconds| waits << seconds }
      stub_request(:post, upload_url)
        .to_return(quota_refusal(reset_at: 150.seconds.from_now))
        .then.to_return(quota_refusal(reset_at: 150.seconds.from_now))
        .then.to_return(uploaded)

      expect(service.upload_blob(blob_path)).to include('blob')

      expect(waits.length).to eq(2)
      expect(waits).to all(be_between(60, 75))
    end

    it 'keeps its own backoff when the PDS gives no hint' do
      stub_request(:post, upload_url).to_return(status: 429, body: 'slow down')

      expect { service.upload_blob(blob_path) }.to raise_error(GoatService::RateLimitError) { |error|
        expect(error).not_to be_a(GoatService::QuotaExhaustedError)
      }
      expect(WebMock).to have_requested(:post, upload_url).times(GoatService::MAX_RATE_LIMIT_RETRIES + 1)
    end

    it 'ignores a reset time that has already passed' do
      stub_request(:post, upload_url)
        .to_return(quota_refusal(reset_at: 30.seconds.ago))
        .then.to_return(uploaded)

      expect(service.upload_blob(blob_path)).to include('blob')
    end
  end

  # Asking the new PDS which files it still lacks lets a restarted or retried
  # transfer skip the ones already there, instead of spending the day's quota
  # on them again.
  describe '#missing_blob_cids' do
    let(:status_url) { "#{migration.new_pds_host}/xrpc/com.atproto.server.checkAccountStatus" }
    let(:missing_url) { %r{\A#{Regexp.escape(migration.new_pds_host)}/xrpc/com\.atproto\.repo\.listMissingBlobs} }

    def account_status(expected:, imported:)
      { status: 200, headers: { 'Content-Type' => 'application/json' },
        body: { activated: false, validDid: true, expectedBlobs: expected, importedBlobs: imported }.to_json }
    end

    def missing_page(cids, cursor: nil)
      body = { blobs: cids.map { |c| { cid: c, recordUri: "at://#{migration.did}/app.bsky.feed.post/#{c}" } } }
      body[:cursor] = cursor if cursor
      { status: 200, headers: { 'Content-Type' => 'application/json' }, body: body.to_json }
    end

    it 'returns the files the new PDS lacks, across pages' do
      stub_request(:get, status_url).to_return(account_status(expected: 5, imported: 2))
      stub_request(:get, missing_url).with(query: { limit: '1000' }).to_return(missing_page(%w[a b], cursor: 'b'))
      stub_request(:get, missing_url).with(query: { limit: '1000', cursor: 'b' }).to_return(missing_page(%w[c]))

      expect(service.missing_blob_cids).to eq(Set['a', 'b', 'c'])
    end

    # Files uploaded but not referenced by any record count as imported, so
    # the list may be longer than expected - imported; never shorter.
    it 'accepts a list longer than expected minus imported' do
      stub_request(:get, status_url).to_return(account_status(expected: 3, imported: 2))
      stub_request(:get, missing_url).to_return(missing_page(%w[a b]))

      expect(service.missing_blob_cids).to eq(Set['a', 'b'])
    end

    it 'returns nil when the list is shorter than the counts say' do
      stub_request(:get, status_url).to_return(account_status(expected: 3022, imported: 0))
      stub_request(:get, missing_url).to_return(missing_page([]))

      expect(service.missing_blob_cids).to be_nil
    end

    it 'returns nil when the new PDS does not implement the list' do
      stub_request(:get, status_url).to_return(account_status(expected: 3, imported: 0))
      stub_request(:get, missing_url).to_return(status: 501, body: { error: 'MethodNotImplemented' }.to_json,
                                                headers: { 'Content-Type' => 'application/json' })

      expect(service.missing_blob_cids).to be_nil
    end

    it 'returns nil when the account status is unavailable' do
      stub_request(:get, status_url).to_return(status: 500, body: '')

      expect(service.missing_blob_cids).to be_nil
    end
  end
end
