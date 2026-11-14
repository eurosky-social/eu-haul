# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Migration, 'spaces stage' do
  let(:migration) do
    described_class.create!(
      email: 'test@example.com',
      did: "did:plc:stage#{SecureRandom.hex(4)}",
      old_handle: 'test.old.example',
      old_pds_host: 'https://old.pds.example',
      new_handle: 'test.new.example',
      new_pds_host: 'https://new.pds.example',
      status: :pending_blobs
    )
  end

  it 'advances from the files to the spaces and enqueues ImportSpacesJob' do
    expect { migration.advance_to_pending_spaces! }.to have_enqueued_job(ImportSpacesJob).with(migration.id)
    expect(migration.reload).to be_pending_spaces
  end

  it 'counts as in progress' do
    migration.update!(status: :pending_spaces)

    expect(described_class.in_progress).to include(migration)
  end

  it 'sits between the files and the preferences in the progress bar' do
    migration.update!(status: :pending_spaces, create_backup_bundle: false)
    spaces = migration.progress_percentage
    migration.update!(status: :pending_prefs)

    expect(spaces).to be > 50 # the end of the files stage without a backup bundle
    expect(spaces).to be < migration.progress_percentage
  end

  it 'has a name on the status page in every locale' do
    I18n.available_locales.each do |locale|
      expect(I18n.exists?('migrations.show.status_names.pending_spaces', locale)).to be(true), locale.to_s
    end
  end

  it 'is resumed and swept like the other stages' do
    expect(StuckMigrationSweeperJob::ACTIVE_STATUSES).to include('pending_spaces')
    expect(EmailHelper::JOB_STEP_STATUSES[/ImportSpacesJob/i]).to eq('pending_spaces')
  end
end
