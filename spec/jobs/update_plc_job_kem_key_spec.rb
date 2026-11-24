# frozen_string_literal: true

require 'rails_helper'

# A spaces-capable new PDS publishes its KEM key (#atproto_kem) through the
# recommended PLC credentials. UpdatePlcJob records whether the operation
# carries it; it never stops the migration over it, because the new PDS
# publishes a missing key itself once the account points there.
RSpec.describe UpdatePlcJob, 'KEM key check', type: :job do
  let(:migration) do
    Migration.create!(
      email: 'test@example.com',
      did: "did:plc:kem#{SecureRandom.hex(4)}",
      old_handle: 'test.old.example',
      old_pds_host: 'https://old.pds.example',
      new_handle: 'test.new.example',
      new_pds_host: 'https://new.pds.example',
      status: :pending_plc,
      progress_data: { 'destination_supports_spaces' => true }
    )
  end
  let(:op_path) { Rails.root.join('tmp', "unsigned-#{SecureRandom.hex(4)}.json").to_s }

  after { FileUtils.rm_f(op_path) }

  def write_op(verification_methods)
    File.write(op_path, { 'verificationMethods' => verification_methods }.to_json)
  end

  it 'records an operation that publishes the KEM key' do
    write_op('atproto' => 'did:key:zSign', 'atproto_kem' => 'did:key:zKem')

    described_class.new.send(:record_kem_key, migration, op_path)

    expect(migration.reload.progress_data['plc_operation_has_kem_key']).to be(true)
  end

  it 'records and logs an operation without it, without stopping' do
    write_op('atproto' => 'did:key:zSign')
    allow(Rails.logger).to receive(:warn)

    described_class.new.send(:record_kem_key, migration, op_path)

    expect(migration.reload.progress_data['plc_operation_has_kem_key']).to be(false)
    expect(migration).to be_pending_plc
    expect(Rails.logger).to have_received(:warn).with(/no atproto_kem key/)
  end

  it 'never raises over an unreadable operation file' do
    expect { described_class.new.send(:record_kem_key, migration, '/nonexistent/op.json') }.not_to raise_error
  end
end
