# frozen_string_literal: true

require 'rails_helper'

# The status page used to say the confirmation-code email comes from Bluesky
# and that the account moved to Eurosky, whatever the two servers were.
RSpec.describe "Status page server names", type: :request do
  def migration(status:, new_pds_host: 'https://pds.oso.social', old_pds_host: 'https://eurosky.social')
    Migration.create!(
      email: 'test@example.com',
      did: 'did:plc:statuspage123',
      old_handle: 'alice.mu.social',
      old_pds_host: old_pds_host,
      new_handle: 'alice.oso.social',
      new_pds_host: new_pds_host,
      status: status
    ).tap { |m| m.update_columns(email_verified_at: Time.current, email_verification_token: nil) }
  end

  # The sender is named the way the inbox shows it: the old server's bare host,
  # or Bluesky itself for the bsky.network shards, which mail from noreply@bsky.app.
  it 'says the confirmation-code email comes from the old server' do
    get "/migrate/#{migration(status: :pending_plc).token}"

    expect(response.body).to include('The email comes from your current server (eurosky.social), not from us')
    expect(response.body).not_to include('comes from Bluesky')
  end

  it 'names Bluesky, not the shard, when the old server is a Bluesky host' do
    get "/migrate/#{migration(status: :pending_plc, old_pds_host: 'https://shimeji.us-east.host.bsky.network').token}"

    expect(response.body).to include('The email comes from your current server (Bluesky (noreply@bsky.app)), not from us')
    expect(response.body).not_to include('server (https://shimeji')
  end

  it 'names the destination once the migration is done' do
    get "/migrate/#{migration(status: :completed).token}"

    expect(response.body).to include('successfully migrated to https://pds.oso.social')
    expect(response.body).not_to include('migrated to Eurosky')
  end

  it 'escapes the destination address in the completion message' do
    get "/migrate/#{migration(status: :completed, new_pds_host: 'https://pds.example.com/<img src=x onerror=alert(1)>').token}"

    expect(response.body).not_to include('<img src=x')
    expect(response.body).to include('migrated to https://pds.example.com/&lt;img src=x onerror=alert(1)&gt;')
  end
end
