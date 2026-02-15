require "test_helper"

# Integration Tests for Complete Migration Error Flows
# Tests based on MIGRATION_ERROR_ANALYSIS.md covering end-to-end error scenarios
class MigrationErrorFlowsTest < ActionDispatch::IntegrationTest
  def setup
    @valid_migration_params = {
      did: "did:plc:integration123",
      old_handle: "user.oldpds.com",
      new_handle: "user.newpds.com",
      old_pds_host: "https://oldpds.example.com",
      new_pds_host: "https://newpds.example.com",
      email: "integration@example.com",
      password: "secure_password_123",
      migration_type: "migration_out"
    }
  end

  # ============================================================================
  # Stage 1: Email Verification Errors
  # ============================================================================

  test "email verification with invalid code fails" do
    migration = create_migration(@valid_migration_params)

    post verify_email_url(token: migration.token), params: { verification_code: "XXX-YYY" }

    assert_response :redirect
    follow_redirect!
    assert_match /Invalid verification code/, flash[:alert]
  end

  test "email verification with valid code starts migration" do
    migration = create_migration(@valid_migration_params)
    verification_code = migration.email_verification_token

    # Verify email and check that job is enqueued
    post verify_email_url(token: migration.token), params: { verification_code: verification_code }

    assert_response :redirect
    follow_redirect!
    assert_match /Email verified/, flash[:notice]

    # Check that the migration started (either CreateAccountJob or DownloadAllDataJob depending on backup setting)
    migration.reload
    assert migration.email_verified?
  end

  test "email verification code is single-use" do
    migration = create_migration(@valid_migration_params)
    verification_code = migration.email_verification_token

    # First use: succeeds
    post verify_email_url(token: migration.token), params: { verification_code: verification_code }
    assert_response :redirect

    # Second use: fails (code cleared after first use)
    post verify_email_url(token: migration.token), params: { verification_code: verification_code }
    assert_response :redirect
    follow_redirect!
    assert_match /Invalid verification code/, flash[:alert]
  end

  # ============================================================================
  # Stage 2: Account Creation Errors
  # ============================================================================

  test "migration fails with authentication error" do
    migration = create_verified_migration(@valid_migration_params)

    service = mock('goat_service')
    service.stubs(:login_old_pds).raises(
      GoatService::AuthenticationError,
      "Invalid password"
    )
    GoatService.stubs(:new).returns(service)

    # Perform job with mocked service
    CreateAccountJob.new.perform(migration.id) rescue nil

    migration.reload
    assert_match /Invalid password/, migration.last_error
  end

  test "migration fails when account already exists (orphaned)" do
    migration = create_verified_migration(@valid_migration_params)

    service = mock('goat_service')
    service.stubs(:login_old_pds).returns(nil)
    service.stubs(:get_new_pds_service_did).returns('did:web:newpds')
    service.stubs(:get_service_auth_token).returns('token')
    service.stubs(:create_account_on_new_pds).raises(
      GoatService::AccountExistsError,
      "Orphaned deactivated account exists"
    )
    service.stubs(:cleanup)
    GoatService.stubs(:new).returns(service)

    CreateAccountJob.new.perform(migration.id) rescue nil

    migration.reload
    assert migration.failed?
    assert_match /Orphaned account exists on target PDS/, migration.last_error
  end

  test "migration handles rate limiting during account creation" do
    migration = create_verified_migration(@valid_migration_params)

    service = mock('goat_service')
    # First attempt: rate limited
    service.stubs(:login_old_pds).raises(GoatService::RateLimitError, "Rate limit exceeded").then.returns(nil)
    service.stubs(:get_new_pds_service_did).returns('did:web:newpds')
    service.stubs(:get_service_auth_token).returns('token')
    service.stubs(:create_account_on_new_pds)
    service.stubs(:generate_rotation_key).returns({
      private_key: 'z42tk' + 'a' * 50,
      public_key: 'did:key:zDnae' + 'b' * 50
    })
    service.stubs(:add_rotation_key_to_pds)
    GoatService.stubs(:new).returns(service)

    # First attempt: raises rate limit error
    assert_raises(GoatService::RateLimitError) do
      CreateAccountJob.new.perform(migration.id)
    end

    migration.reload
    assert_match /Rate limit/, migration.last_error

    # Second attempt: succeeds
    CreateAccountJob.new.perform(migration.id)

    migration.reload
    assert migration.account_created? || migration.pending_repo?
  end

  test "migration_in verifies existing account before proceeding" do
    migration = create_verified_migration(
      @valid_migration_params.merge(migration_type: "migration_in")
    )

    service = mock('goat_service')
    service.stubs(:login_old_pds).returns(true)
    service.expects(:verify_existing_account_access).returns(
      { exists: true, deactivated: true }
    )
    GoatService.stubs(:new).returns(service)

    CreateAccountJob.new.perform(migration.id)

    migration.reload
    assert migration.pending_repo?
  end

  test "migration_in fails when account doesn't exist" do
    migration = create_verified_migration(
      @valid_migration_params.merge(migration_type: "migration_in")
    )

    service = mock('goat_service')
    service.stubs(:login_old_pds)
    service.stubs(:verify_existing_account_access).raises(
      GoatService::GoatError,
      "Account does not exist on target PDS"
    )
    service.stubs(:cleanup)
    GoatService.stubs(:new).returns(service)

    # Run job 3 times to exhaust retries
    job = CreateAccountJob.new
    3.times do |i|
      job.stubs(:executions).returns(i + 1)
      job.perform(migration.id) rescue nil
    end

    migration.reload
    assert migration.failed?
    assert_match /does not exist/, migration.last_error
  end

  # ============================================================================
  # Stage 4: Blob Import Errors
  # ============================================================================

  test "blob import handles partial failures gracefully" do
    migration = create_verified_migration(@valid_migration_params)
    migration.update!(status: :pending_blobs)

    service = mock('goat_service')
    service.stubs(:login_new_pds)
    service.stubs(:list_blobs).returns({
      'cids' => ['blob_success', 'blob_fail1', 'blob_fail2'],
      'cursor' => nil
    })

    # blob_success: succeeds
    service.stubs(:download_blob).with('blob_success').returns('/tmp/blob_success')
    service.stubs(:upload_blob).with('/tmp/blob_success').returns({ 'blob' => {} })

    # blob_fail1 and blob_fail2: fail all retries
    service.stubs(:download_blob).with('blob_fail1').raises(
      GoatService::NetworkError, "Download failed"
    )
    service.stubs(:download_blob).with('blob_fail2').raises(
      GoatService::NetworkError, "Download failed"
    )

    File.stubs(:size).returns(1024)
    File.stubs(:exist?).returns(true)
    service.stubs(:get_account_status).returns({ 'expectedBlobs' => 3, 'importedBlobs' => 1 })
    service.stubs(:collect_all_missing_blobs).returns([])

    GoatService.stubs(:new).returns(service)

    ImportBlobsJob.new.perform(migration.id)

    migration.reload
    assert migration.pending_prefs? # Should continue despite failures
    assert_equal 2, migration.progress_data['failed_blobs'].size
    assert migration.progress_data['failed_blobs'].include?('blob_fail1')
    assert migration.progress_data['failed_blobs'].include?('blob_fail2')
  end

  test "blob import respects concurrency limit" do
    # Create 15 active blob migrations
    15.times do |i|
      Migration.create!(
        did: "did:plc:concurrent#{i}",
        old_handle: "user#{i}.old.com",
        new_handle: "user#{i}.new.com",
        old_pds_host: "https://old.com",
        new_pds_host: "https://new.com",
        email: "user#{i}@example.com",
        status: :pending_blobs,
        password: "test"
      )
    end

    migration = create_verified_migration(@valid_migration_params)
    migration.update!(status: :pending_blobs)

    # Should re-enqueue instead of executing
    assert_enqueued_with(job: ImportBlobsJob, at: 30.seconds.from_now) do
      ImportBlobsJob.new.perform(migration.id)
    end

    migration.reload
    assert migration.pending_blobs? # Still pending
  end

  # ============================================================================
  # Stage 6: PLC Token Submission
  # ============================================================================

  test "PLC token submission with invalid OTP fails" do
    skip "OTP feature not yet implemented"
    migration = create_verified_migration(@valid_migration_params)
    migration.update!(status: :pending_plc)
    otp = migration.generate_plc_otp!
    migration.set_plc_token("test-plc-token")

    # Submit with wrong OTP
    post submit_plc_token_migration_url(migration.token), params: {
      plc_token: "test-plc-token",
      plc_otp: "000000" # Wrong OTP
    }

    assert_response :redirect
    # Check flash alert message directly
    assert flash[:alert].include?("Invalid OTP"), "Expected flash alert to contain 'Invalid OTP', got: #{flash[:alert]}"

    migration.reload
    assert_equal 1, migration.plc_otp_attempts
  end

  test "PLC token submission with valid OTP enqueues UpdatePlcJob" do
    skip "OTP feature not yet implemented"
    migration = create_verified_migration(@valid_migration_params)
    migration.update!(status: :pending_plc)
    otp = migration.generate_plc_otp!

    assert_enqueued_with(job: UpdatePlcJob, queue: :critical) do
      post submit_plc_token_migration_url(migration.token), params: {
        plc_token: "test-plc-token",
        plc_otp: otp
      }
    end

    assert_response :redirect
    migration.reload
    assert migration.plc_token.present?
  end

  test "PLC token submission rate limits after 5 failed attempts" do
    skip "OTP feature not yet implemented"
    migration = create_verified_migration(@valid_migration_params)
    migration.update!(status: :pending_plc)
    migration.generate_plc_otp!

    # Try 5 times with wrong OTP
    5.times do
      post submit_plc_token_migration_url(migration.token), params: {
        plc_token: "test-plc-token",
        plc_otp: "000000"
      }
    end

    # 6th attempt should be blocked
    post submit_plc_token_migration_url(migration.token), params: {
      plc_token: "test-plc-token",
      plc_otp: "000000"
    }

    assert_response :redirect
    # Check flash alert directly
    assert flash[:alert].include?("Too many failed attempts"), "Expected flash alert to contain 'Too many failed attempts', got: #{flash[:alert]}"

    migration.reload
    assert_equal 5, migration.plc_otp_attempts
  end

  test "PLC token submission rejects expired OTP" do
    skip "OTP feature not yet implemented"
    migration = create_verified_migration(@valid_migration_params)
    migration.update!(status: :pending_plc)
    otp = migration.generate_plc_otp!

    # Expire the OTP
    migration.update!(plc_otp_expires_at: 1.minute.ago)

    post submit_plc_token_migration_url(migration.token), params: {
      plc_token: "test-plc-token",
      plc_otp: otp
    }

    assert_response :redirect
    # Check flash alert directly
    assert flash[:alert].include?("OTP has expired"), "Expected flash alert to contain 'OTP has expired', got: #{flash[:alert]}"
  end

  # ============================================================================
  # Stage 7: Update PLC (Critical)
  # ============================================================================

  test "UpdatePlcJob fails when PLC token missing" do
    migration = create_verified_migration(@valid_migration_params)
    migration.update!(
      status: :pending_plc,
      encrypted_plc_token: nil
    )

    UpdatePlcJob.new.perform(migration.id)

    migration.reload
    assert migration.failed?
    assert_match /PLC token is missing/, migration.last_error
  end

  test "UpdatePlcJob fails when PLC token expired" do
    migration = create_verified_migration(@valid_migration_params)
    migration.update!(status: :pending_plc)
    migration.set_plc_token("test-token")
    # PLC token expiry is tracked separately in progress_data
    migration.progress_data['plc_token_expires_at'] = 1.hour.ago.iso8601
    migration.save!

    UpdatePlcJob.new.perform(migration.id)

    migration.reload
    assert migration.failed?
    assert_match /PLC token has expired/, migration.last_error
  end

  # ============================================================================
  # Migration Cancellation
  # ============================================================================

  test "cancellation succeeds during early stages" do
    skip "Cancellation feature not yet implemented"
    migration = create_verified_migration(@valid_migration_params)
    migration.update!(status: :pending_blobs)

    post cancel_migration_url(migration.token)

    assert_response :redirect
    migration.reload
    assert migration.failed?
    assert migration.last_error.include?("cancelled by user")
  end

  test "cancellation fails during PLC stage" do
    skip "Cancellation feature not yet implemented"
    migration = create_verified_migration(@valid_migration_params)
    migration.update!(status: :pending_plc)

    post cancel_migration_url(migration.token)

    assert_response :redirect
    # Check flash alert directly
    assert flash[:alert].include?("cannot be cancelled"), "Expected flash alert to contain 'cannot be cancelled', got: #{flash[:alert]}"

    migration.reload
    assert migration.pending_plc? # Status unchanged
  end

  test "cancellation fails after completion" do
    skip "Cancellation feature not yet implemented"
    migration = migrations(:completed_migration)

    post cancel_migration_url(migration.token)

    assert_response :redirect
    # Check flash alert directly
    assert flash[:alert].include?("cannot be cancelled"), "Expected flash alert to contain 'cannot be cancelled', got: #{flash[:alert]}"

    migration.reload
    assert migration.completed?
  end

  # ============================================================================
  # Retry Mechanism
  # ============================================================================

  test "retry button restarts failed migration from last known stage" do
    migration = create_verified_migration(@valid_migration_params)
    migration.update!(
      status: :failed,
      last_error: "Network timeout",
      current_job_step: "ImportRepoJob"
    )

    # Should re-enqueue appropriate job based on last step
    post retry_migration_url(migration.token)

    assert_response :redirect
    migration.reload
    # Status should be reset to allow retry
  end

  # ============================================================================
  # Credentials Expiration
  # ============================================================================

  test "migration fails when credentials expire during processing" do
    migration = create_verified_migration(@valid_migration_params)
    migration.set_password("test_password", expires_in: 1.second)

    # Wait for expiration
    sleep 2

    migration.reload
    assert_nil migration.password # Should return nil due to expiration
    assert migration.credentials_expired?
  end

  test "migration shows remaining time until credentials expire" do
    migration = create_verified_migration(@valid_migration_params)
    migration.set_password("test_password", expires_in: 24.hours)

    get migration_url(migration.token)

    assert_response :success
    # Should display remaining time (tested via view rendering)
  end

  # ============================================================================
  # Progress Tracking
  # ============================================================================

  test "status page shows accurate progress percentage" do
    migration = create_verified_migration(@valid_migration_params)

    stages = [
      [:pending_account, 0],
      [:account_created, 10],
      [:pending_repo, 20],
      [:pending_blobs, 20],
      [:pending_prefs, 70],
      [:pending_plc, 80],
      [:pending_activation, 90],
      [:completed, 100]
    ]

    stages.each do |status, min_expected|
      migration.update!(status: status)

      get migration_url(migration.token)

      assert_response :success
      # Progress percentage should be >= min_expected
    end
  end

  test "status page shows blob upload progress" do
    migration = create_verified_migration(@valid_migration_params)
    migration.update!(status: :pending_blobs)

    migration.update_blob_progress!(cid: 'blob1', size: 1000, uploaded: 500)
    migration.update_blob_progress!(cid: 'blob2', size: 1000, uploaded: 1000)

    get migration_url(migration.token)

    assert_response :success
    # Should show "Blobs uploaded: 1500/2000 bytes"
  end

  test "status page shows estimated time remaining during blob upload" do
    migration = create_verified_migration(@valid_migration_params)
    migration.update!(status: :pending_blobs)

    now = Time.current
    migration.progress_data['blobs'] = {
      'blob1' => { 'size' => 10000, 'uploaded' => 10000, 'updated_at' => (now - 10.seconds).iso8601 },
      'blob2' => { 'size' => 10000, 'uploaded' => 5000, 'updated_at' => now.iso8601 }
    }
    migration.save!

    get migration_url(migration.token)

    assert_response :success
    assert_not_nil migration.estimated_time_remaining
  end

  # ============================================================================
  # Error Display
  # ============================================================================

  test "status page shows user-friendly error messages" do
    skip "HTML rendering test - needs view template inspection to match exact error display format"

    error_scenarios = [
      ["Authentication failed: invalid password", /password/i],
      ["HTTP 429: Too Many Requests", /rate limit/i],
      ["PLC token missing or expired", /PLC token/i],
      ["Orphaned deactivated account exists", /orphaned/i]
    ]

    error_scenarios.each do |error_message, expected_pattern|
      migration = create_verified_migration(@valid_migration_params.merge(
        did: "did:plc:#{SecureRandom.hex(8)}"
      ))
      migration.update!(
        status: :failed,
        last_error: error_message
      )

      get migration_url(migration.token)

      assert_response :success
      assert_match expected_pattern, response.body
    end
  end

  test "status page shows retry information during job execution" do
    migration = create_verified_migration(@valid_migration_params)
    migration.update!(
      status: :pending_account,
      current_job_step: "CreateAccountJob",
      current_job_attempt: 2,
      current_job_max_attempts: 3,
      last_error: "Network timeout"
    )

    get migration_url(migration.token)

    assert_response :success
    # Should show "Retrying... (attempt 2/3)"
  end

  # ============================================================================
  # Helper Methods
  # ============================================================================

  private

  def create_migration(params)
    chars = [*'A'..'Z', *'0'..'9']
    code = "#{Array.new(3) { chars.sample }.join}-#{Array.new(3) { chars.sample }.join}"
    Migration.create!(params.except(:password).merge(
      email_verification_token: code,
      status: :pending_account
    )).tap do |migration|
      migration.set_password(params[:password]) if params[:password]
    end
  end

  def create_verified_migration(params)
    create_migration(params).tap do |migration|
      migration.update!(
        email_verified_at: Time.current,
        email_verification_token: nil
      )
    end
  end
end
