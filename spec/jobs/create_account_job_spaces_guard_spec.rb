# frozen_string_literal: true

require 'rails_helper'

# From 1 December 2026 an account can have spaces. Until eu-haul's spaces
# move has been rehearsed against the release (EUR-696) it stays off
# (MOVE_SPACES), and an account with spaces must not move without them
# (EUR-636). The check comes first: before anything is created on the new
# PDS, so the files don't spend its upload quota and a later attempt doesn't
# run into a half-made account there.
RSpec.describe CreateAccountJob, 'spaces guard' do
  let(:migration) do
    Migration.create!(
      email: 'test@example.com',
      did: "did:plc:guard#{SecureRandom.hex(4)}",
      old_handle: 'alice.eurosky.social',
      old_pds_host: 'https://eurosky.social',
      new_handle: 'alice.example.com',
      new_pds_host: 'https://new.pds.example',
      status: :pending_account
    )
  end
  let(:goat) { instance_double(GoatService) }
  let(:space) { "at://#{migration.did}/space/com.example.forum/general" }

  before do
    allow(GoatService).to receive(:new).with(migration).and_return(goat)
    allow(goat).to receive(:login_old_pds)
    allow(goat).to receive(:get_new_pds_service_did).and_return('did:web:new.pds.example')
    allow(goat).to receive(:get_service_auth_token).and_return('service-auth')
    allow(goat).to receive(:create_account_on_new_pds)
  end

  context 'with the spaces move off (the default)' do
    it 'stops an account with spaces before creating anything on the new PDS' do
      allow(goat).to receive(:list_spaces).with(:old).and_return([{ 'space' => space }])

      described_class.perform_now(migration.id)

      migration.reload
      expect(migration).to be_failed
      expect(migration.error_code).to eq('spaces_not_moved')
      expect(migration.progress_data['spaces_total']).to eq(1)
      expect(goat).not_to have_received(:get_service_auth_token)
      expect(goat).not_to have_received(:create_account_on_new_pds)
    end

    it 'tells the user by email' do
      allow(goat).to receive(:list_spaces).with(:old).and_return([{ 'space' => space }])

      expect { described_class.perform_now(migration.id) }
        .to have_enqueued_mail(MigrationMailer, :migration_failed)
    end

    it 'moves an account without spaces as before' do
      allow(goat).to receive(:list_spaces).with(:old).and_return([])

      described_class.perform_now(migration.id)

      expect(goat).to have_received(:create_account_on_new_pds)
      expect(migration.reload).not_to be_failed
    end

    it 'moves an account whose old PDS has no spaces' do
      allow(goat).to receive(:list_spaces).with(:old).and_raise(GoatService::SpacesUnsupportedError, '501')

      described_class.perform_now(migration.id)

      expect(goat).to have_received(:create_account_on_new_pds)
    end
  end

  context 'with the spaces move on' do
    before { allow(EuroskyConfig).to receive(:move_spaces?).and_return(true) }

    it 'leaves the spaces to the spaces stage' do
      allow(goat).to receive(:list_spaces)

      described_class.perform_now(migration.id)

      expect(goat).not_to have_received(:list_spaces)
      expect(goat).to have_received(:create_account_on_new_pds)
    end
  end

  describe 'EuroskyConfig.move_spaces?' do
    before { allow(ENV).to receive(:fetch).and_call_original }

    it 'is off unless MOVE_SPACES says true' do
      allow(ENV).to receive(:fetch).with('MOVE_SPACES', 'false').and_return('false')
      expect(EuroskyConfig.move_spaces?).to be(false)

      allow(ENV).to receive(:fetch).with('MOVE_SPACES', 'false').and_return(' TRUE ')
      expect(EuroskyConfig.move_spaces?).to be(true)
    end
  end
end
