require "test_helper"

# MigrationsController PLC Token Tests
# Tests for PLC token expiration handling and resend functionality
class MigrationsControllerPlcTokenTest < ActionDispatch::IntegrationTest
  def setup
    @pending_plc_migration = migrations(:pending_migration)
    @pending_plc_migration.update!(
      status: :pending_plc,
      old_pds_host: 'https://oldpds.example.com',
      new_pds_host: 'https://newpds.example.com'
    )
    # Set old PDS tokens so controller can call GoatService.request_plc_token
    @pending_plc_migration.set_old_pds_tokens!(
      access_token: "test_old_access",
      refresh_token: "test_old_refresh"
    )
    @pending_plc_migration.set_plc_token("ABCDE-FGHIJ")
  end

  # ============================================================================
  # request_new_plc_token Action Tests
  # ============================================================================

  test "request_new_plc_token successfully requests new token when migration is pending_plc" do
    service = mock('goat_service')
    service.expects(:request_plc_token).once
    GoatService.stubs(:new).returns(service)

    post request_new_plc_token_by_token_path(@pending_plc_migration.token)

    assert_redirected_to migration_by_token_path(@pending_plc_migration.token)
    assert_match(/new PLC token has been requested/i, flash[:notice])
    # The sender is named the way the inbox shows it: bare host, no scheme
    assert_includes flash[:notice], "oldpds.example.com"
    refute_includes flash[:notice], "https://"

    @pending_plc_migration.reload
    assert @pending_plc_migration.progress_data['plc_token_requested_at'].present?
    assert @pending_plc_migration.progress_data['plc_token_resent']
  end

  test "request_new_plc_token resets failed migration with expired token to pending_plc" do
    @pending_plc_migration.update!(
      status: :failed,
      last_error: "PLC token has expired (expired at: #{1.hour.ago}). Please request a new token."
    )

    service = mock('goat_service')
    service.expects(:request_plc_token).once
    GoatService.stubs(:new).returns(service)

    post request_new_plc_token_by_token_path(@pending_plc_migration.token)

    @pending_plc_migration.reload
    assert @pending_plc_migration.pending_plc?
    assert_nil @pending_plc_migration.last_error
  end

  test "request_new_plc_token rejects request when migration not in correct status" do
    @pending_plc_migration.update!(status: :completed)

    post request_new_plc_token_by_token_path(@pending_plc_migration.token)

    assert_redirected_to migration_by_token_path(@pending_plc_migration.token)
    assert_match(/cannot request.*at this stage/i, flash[:alert])
  end

  test "request_new_plc_token allows request when migration failed with PLC token error" do
    @pending_plc_migration.update!(
      status: :failed,
      last_error: "PLC token has expired. Please request a new token."
    )

    service = mock('goat_service')
    service.expects(:request_plc_token).once
    GoatService.stubs(:new).returns(service)

    post request_new_plc_token_by_token_path(@pending_plc_migration.token)

    assert_redirected_to migration_by_token_path(@pending_plc_migration.token)
    assert_match(/new PLC token has been requested/i, flash[:notice])
  end

  test "request_new_plc_token rejects request when migration failed without PLC token error" do
    @pending_plc_migration.update!(
      status: :failed,
      last_error: "Network error during blob transfer"
    )

    post request_new_plc_token_by_token_path(@pending_plc_migration.token)

    assert_redirected_to migration_by_token_path(@pending_plc_migration.token)
    assert_match(/cannot request.*at this stage/i, flash[:alert])
  end

  test "request_new_plc_token handles GoatService error gracefully" do
    service = mock('goat_service')
    service.stubs(:request_plc_token).raises(GoatService::NetworkError, "Network timeout")
    GoatService.stubs(:new).returns(service)

    post request_new_plc_token_by_token_path(@pending_plc_migration.token)

    assert_redirected_to migration_by_token_path(@pending_plc_migration.token)
    # Controller falls back to manual instructions when API call fails
    assert_match(/Could not automatically request.*new PLC token/i, flash[:notice])
  end

  # ============================================================================
  # Integration with submit_plc_token Action
  # ============================================================================

  test "submit_plc_token triggers UpdatePlcJob with new token after resend" do
    # Simulate token resend + ensure credentials are present (submit_plc_token validates them)
    @pending_plc_migration.set_password("test_password")
    @pending_plc_migration.progress_data['plc_token_resent'] = true
    @pending_plc_migration.save!

    assert_enqueued_with(job: UpdatePlcJob, args: [@pending_plc_migration.id]) do
      post submit_plc_token_by_token_path(@pending_plc_migration.token),
           params: { plc_token: "KLMNO-PQRST" }
    end

    assert_redirected_to migration_by_token_path(@pending_plc_migration.token)
    assert_match(/PLC token submitted/i, flash[:notice])

    @pending_plc_migration.reload
    assert_equal "KLMNO-PQRST", @pending_plc_migration.plc_token
  end

# ============================================================================
# Token normalisation and format check
#
# The PDS upper-cases the code and otherwise compares it verbatim, so what
# the user pastes has to be cleaned up here — and anything that cannot be a
# code (eu-haul's own XXX-XXX verification code, the EURO- migration token,
# a truncated paste) is bounced before a failed signing round trip.
# ============================================================================

test "submit_plc_token upper-cases the code and drops pasted whitespace" do
  @pending_plc_migration.set_password("test_password")

  assert_enqueued_with(job: UpdatePlcJob, args: [@pending_plc_migration.id]) do
    post submit_plc_token_by_token_path(@pending_plc_migration.token),
         params: { plc_token: "  abcde-fghij \n" }
  end

  assert_equal "ABCDE-FGHIJ", @pending_plc_migration.reload.plc_token
end

test "submit_plc_token restores the dash when the code was pasted without it" do
  @pending_plc_migration.set_password("test_password")

  post submit_plc_token_by_token_path(@pending_plc_migration.token),
       params: { plc_token: "abcdefghij" }

  assert_equal "ABCDE-FGHIJ", @pending_plc_migration.reload.plc_token
end

test "submit_plc_token bounces anything that is not a XXXXX-XXXXX code before calling the PDS" do
  @pending_plc_migration.set_password("test_password")
  @pending_plc_migration.update!(encrypted_plc_token: nil)

  ["ABC-123", "EURO-TESTTOK123456789", "ABCDE-FGHI", "code: ABCDE-FGHIJ"].each do |wrong|
    assert_no_enqueued_jobs(only: UpdatePlcJob) do
      post submit_plc_token_by_token_path(@pending_plc_migration.token), params: { plc_token: wrong }
    end

    assert_redirected_to migration_by_token_path(@pending_plc_migration.token)
    assert_includes flash[:alert], "XXXXX-XXXXX", "#{wrong.inspect} should have been bounced"
    assert_nil @pending_plc_migration.reload.encrypted_plc_token
  end
end

test "the format alert names Bluesky as the sender for a Bluesky-hosted account" do
  @pending_plc_migration.update!(old_pds_host: "https://shimeji.us-east.host.bsky.network")

  post submit_plc_token_by_token_path(@pending_plc_migration.token), params: { plc_token: "ABC-123" }

  assert_includes flash[:alert], "Bluesky (noreply@bsky.app)"
  refute_includes flash[:alert], "shimeji"
end

# ============================================================================
# Status page copy
# ============================================================================

test "the status page tells a Bluesky user to look for mail from Bluesky, not the shard" do
  @pending_plc_migration.update!(old_pds_host: "https://shimeji.us-east.host.bsky.network", encrypted_plc_token: nil)

  get migration_by_token_path(@pending_plc_migration.token)

  assert_response :success
  assert_includes response.body, "Bluesky (noreply@bsky.app)"
  assert_includes response.body, "15 minutes"
  refute_match(/1 hour/, response.body)
end
end
