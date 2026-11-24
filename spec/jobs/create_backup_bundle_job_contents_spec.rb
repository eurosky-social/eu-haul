# frozen_string_literal: true

require 'rails_helper'
require 'zip'

# From 1 December 2026 an account can have spaces, and the backup bundle
# doesn't hold them. It also never held the account's settings or direct
# messages. So it must not call itself complete or say it can restore the
# account (EUR-639).
RSpec.describe 'What the backup says it holds' do
  let(:data_dir) { Rails.root.join('tmp', 'migrations', "contents-#{SecureRandom.hex(4)}") }
  let(:migration) do
    Migration.create!(
      email: 'test@example.com',
      did: "did:plc:contents#{SecureRandom.hex(4)}",
      old_handle: 'alice.eurosky.social',
      old_pds_host: 'https://eurosky.social',
      new_handle: 'alice.example.com',
      new_pds_host: 'https://new.pds.example',
      status: :pending_backup,
      downloaded_data_path: data_dir.to_s
    ).tap { |m| m.update_columns(email_verified_at: Time.current, email_verification_token: nil) }
  end

  before do
    FileUtils.mkdir_p(data_dir.join('blobs'))
    File.write(data_dir.join('repo.car'), 'CAR')
    File.write(data_dir.join('blobs', 'bafyone'), 'IMAGE')
  end

  after do
    FileUtils.rm_rf(data_dir)
    FileUtils.rm_rf(Rails.root.join('tmp', 'bundles', migration.token))
  end

  describe 'the bundle' do
    let(:metadata) do
      CreateBackupBundleJob.perform_now(migration.id)
      Zip::File.open(migration.reload.backup_bundle_path) { |zip| JSON.parse(zip.read('metadata.json')) }
    end

    it 'says what it leaves out' do
      expect(metadata['not_included']).to eq(%w[spaces preferences direct_messages])
      expect(metadata['instructions']).to include('does not contain your atproto spaces')
    end

    it 'no longer calls itself complete or says it restores the account' do
      expect(metadata['instructions']).not_to match(/complete|restore your account/i)
    end
  end

  it 'says so in the backup-ready mail' do
    migration.update!(backup_bundle_path: data_dir.join('repo.car').to_s, backup_expires_at: 1.day.from_now)

    mail = MigrationMailer.backup_ready(migration)

    expect(mail.text_part.body.to_s).to include("It doesn't hold your Spaces")
    expect(mail.html_part.body.to_s).to include('hold your Spaces')
  end

  describe 'the pages', type: :request do
    it 'says so next to the download' do
      migration.update!(status: :pending_repo, backup_bundle_path: data_dir.join('repo.car').to_s,
                        backup_expires_at: 1.day.from_now)

      get "/migrate/#{migration.token}"

      expect(CGI.unescapeHTML(response.body)).to include("It doesn't hold your Spaces")
    end

    it 'offers a backup of the public posts, not of the whole account' do
      get '/migrations/new'

      expect(response.body).to include('Downloads a copy of your public posts and their files, without your Spaces.')
      expect(response.body).not_to include('complete copy of your account data')
    end
  end
end
