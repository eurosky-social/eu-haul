# frozen_string_literal: true

require 'rails_helper'

# While files wait for the new PDS's daily upload quota, a retry is refused, so
# the page says when they go instead of offering one.
RSpec.describe 'Status page while files wait for the daily upload limit', type: :request do
  let(:retry_at) { Time.utc(2030, 1, 2, 19, 15) }
  let(:migration) do
    Migration.create!(
      email: 'test@example.com',
      did: 'did:plc:dailylimit123',
      old_handle: 'alice.eurosky.social',
      old_pds_host: 'https://eurosky.social',
      new_handle: 'alice.bsky.social',
      new_pds_host: 'https://bsky.social',
      status: :pending_plc,
      progress_data: { 'failed_blobs' => %w[bafya bafyb],
                       'blobs_quota_retry_at' => retry_at.iso8601,
                       'blobs_auto_retry_scheduled_at' => Time.current.iso8601 }
    ).tap { |m| m.update_columns(email_verified_at: Time.current, email_verification_token: nil) }
  end

  it 'says when the remaining files are sent, instead of offering a retry' do
    get "/migrate/#{migration.token}"

    expect(response.body).to include('bsky.social accepts only a limited number of files per account each day')
    expect(response.body).to include('The remaining files are sent automatically from 2030-01-02 19:15 UTC.')
    expect(response.body).not_to include('Retry failed files')
  end

  it 'offers the retry again once that time has passed' do
    migration.merge_progress!('blobs_quota_retry_at' => 1.minute.ago.utc.iso8601)

    get "/migrate/#{migration.token}"

    expect(response.body).to include('Retry failed files')
    expect(response.body).not_to include('accepts only a limited number of files')
  end

  # Space files the quota left behind are missing files like any other.
  context 'when only space files are missing' do
    before do
      migration.merge_progress!('failed_blobs' => [], 'blobs_quota_retry_at' => nil,
                                'failed_space_blobs' => [{ 'space' => 'at://x/space/a/b', 'cid' => 'bafys' }])
    end

    it 'shows them and offers the retry' do
      get "/migrate/#{migration.token}"

      expect(response.body).to include('Files not transferred yet: 1')
      expect(response.body).to include('Retry failed files')
    end

    it 'accepts the retry' do
      post "/migrate/#{migration.token}/retry_failed_blobs"

      expect(RetryFailedBlobsJob).to have_been_enqueued.with(migration.id, [])
    end
  end

end
