# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImportSpacesJob, type: :job do
  let(:did) { "did:plc:spacesjob#{SecureRandom.hex(4)}" }
  let(:space) { "at://#{did}/space/com.example.forum/general" }
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
  let(:transfer) { instance_double(SpaceTransferService) }
  let(:result) { SpaceTransferService::Result.new(spaces: 1, repos: 1, blobs: 2, failed_blobs: []) }

  before do
    allow(GoatService).to receive(:new).with(migration).and_return(goat)
    allow(SpaceTransferService).to receive(:new).with(migration, goat: goat).and_return(transfer)
    allow(transfer).to receive(:transfer).and_return(result)
  end

  context 'when the account has no spaces' do
    before { allow(goat).to receive(:list_spaces).with(:old).and_return([]) }

    it 'moves on to the preferences' do
      expect { described_class.perform_now(migration.id) }.to have_enqueued_job(ImportPrefsJob)

      expect(migration.reload).to be_pending_prefs
      expect(migration.progress_data['spaces_total']).to eq(0)
      expect(transfer).not_to have_received(:transfer)
    end

    it 'never calls the new PDS about spaces' do
      described_class.perform_now(migration.id)

      expect(SpaceTransferService).not_to have_received(:new)
      expect(migration.reload.progress_data).not_to have_key('destination_supports_spaces')
    end
  end

  context 'when the old PDS has no spaces support' do
    before { allow(goat).to receive(:list_spaces).with(:old).and_raise(GoatService::SpacesUnsupportedError, '501') }

    it 'treats the account as having no spaces' do
      described_class.perform_now(migration.id)

      expect(migration.reload).to be_pending_prefs
      expect(migration.progress_data['spaces_total']).to eq(0)
    end
  end

  # The account-creation step stops accounts with spaces while the move is
  # off. One that gets spaces during the migration is stopped here, still
  # before the PLC step.
  context 'when the account has spaces and the spaces move is off' do
    before { allow(goat).to receive(:list_spaces).with(:old).and_return([{ 'space' => space }]) }

    it 'stops before the PLC step without moving them' do
      expect { described_class.perform_now(migration.id) }.not_to have_enqueued_job(ImportPrefsJob)

      migration.reload
      expect(migration).to be_failed
      expect(migration.error_code).to eq('spaces_not_moved')
      expect(transfer).not_to have_received(:transfer)
      expect(MigrationErrorHelper.explain_error(migration)[:title]).to eq("eu-haul can't move Spaces yet")
    end
  end

  context 'when the account has spaces' do
    before do
      allow(EuroskyConfig).to receive(:move_spaces?).and_return(true)
      allow(goat).to receive(:list_spaces).with(:old).and_return([{ 'space' => space }])
    end

    it 'moves them and records the counts' do
      described_class.perform_now(migration.id)

      expect(transfer).to have_received(:transfer).with([{ 'space' => space }])
      progress = migration.reload.progress_data
      expect(migration).to be_pending_prefs
      expect(progress).to include('spaces_total' => 1, 'space_repos_moved' => 1, 'space_blobs_moved' => 2,
                                  'failed_space_blobs' => [])
      expect(progress['spaces_completed_at']).to be_present
      expect(progress['destination_supports_spaces']).to be(true)
    end

    it 'stops before the PLC step when the new PDS has no spaces support' do
      allow(transfer).to receive(:transfer)
        .and_raise(GoatService::SpacesUnsupportedError, 'com.atproto.space.importSpaceMeta: 501 MethodNotImplemented')

      expect { described_class.perform_now(migration.id) }.not_to have_enqueued_job(ImportPrefsJob)

      migration.reload
      expect(migration).to be_failed
      expect(migration.error_code).to eq('spaces_unsupported')
      expect(migration.progress_data['destination_supports_spaces']).to be(false)
      expect(MigrationErrorHelper.explain_error(migration)[:title]).to include('Spaces')
    end

    it 'stops without retrying when the new PDS refuses the data' do
      allow(transfer).to receive(:transfer).and_raise(GoatService::SpaceImportRejectedError, 'InvalidRepoFile')

      expect { described_class.perform_now(migration.id) }.not_to have_enqueued_job(described_class)

      migration.reload
      expect(migration).to be_failed
      expect(migration.error_code).to eq('spaces_rejected')
    end

    it 'retries a network failure' do
      allow(transfer).to receive(:transfer).and_raise(GoatService::SpaceRequestError, '500 Internal Server Error')

      expect { described_class.perform_now(migration.id) }.to have_enqueued_job(described_class)
      expect(migration.reload).to be_pending_spaces
    end
  end

  it 'skips a migration that is already past this stage' do
    migration.update!(status: :pending_prefs)

    expect(GoatService).not_to receive(:new)
    described_class.perform_now(migration.id)
  end

  # Space files the quota stopped wait for the pass at the reset. The public
  # files share that quota, so they share the chain: a pass already coming
  # takes them along.
  context "when the new PDS's daily upload quota stops the space files" do
    let(:reset_at) { 8.hours.from_now.change(usec: 0) }
    let(:quota_error) do
      GoatService::QuotaExhaustedError.new('429', reset_at: reset_at, http_status: 429, phase: :upload)
    end
    let(:left) { [{ 'space' => space, 'cid' => 'bafyspace1' }] }
    let(:result) do
      SpaceTransferService::Result.new(spaces: 1, repos: 1, blobs: 0, failed_blobs: left, quota_error: quota_error)
    end

    before do
      allow(EuroskyConfig).to receive(:move_spaces?).and_return(true)
      allow(goat).to receive(:list_spaces).with(:old).and_return([{ 'space' => space }])
    end

    it 'schedules a pass for the reset when none is coming' do
      described_class.perform_now(migration.id)

      expect(RetryFailedBlobsJob).to have_been_enqueued
        .with(migration.id, [], 1).at(reset_at + RetryFailedBlobsJob::QUOTA_RESET_MARGIN)
      expect(migration.reload.progress_data['failed_space_blobs']).to eq(left)
      expect(migration).to be_pending_prefs
    end

    it 'leaves them to the pass already coming for the public files' do
      migration.merge_progress!('failed_blobs' => %w[bafypublic], 'blobs_auto_retry_scheduled_at' => Time.current.iso8601)

      described_class.perform_now(migration.id)

      expect(RetryFailedBlobsJob).not_to have_been_enqueued
    end
  end

end
