require "test_helper"

# Migration Jobs Error Handling Tests
# Tests based on MIGRATION_ERROR_ANALYSIS.md covering error scenarios for all jobs
class MigrationJobsErrorTest < ActiveSupport::TestCase
  def setup
    @migration = migrations(:pending_migration)
  end

  # ============================================================================
  # CreateAccountJob - Stage 2 Errors
  # ============================================================================

  test "CreateAccountJob marks migration failed after max retries" do
    job = CreateAccountJob.new
    service = mock('goat_service')
    service.stubs(:login_old_pds).raises(GoatService::AuthenticationError, "Invalid password")
    GoatService.stubs(:new).returns(service)

    # Stub Sidekiq retry to not actually retry
    job.stubs(:retry_job).raises(Sidekiq::JobRetry::Skip)

    assert_raises(Sidekiq::JobRetry::Skip) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.failed?
    assert @migration.last_error.include?("Invalid password")
  end

  test "CreateAccountJob handles AccountExistsError by discarding job" do
    job = CreateAccountJob.new
    service = mock('goat_service')
    service.stubs(:login_old_pds).returns(nil)
    service.stubs(:get_new_pds_service_did).returns('did:web:newpds')
    service.stubs(:get_service_auth_token).returns('token')
    service.stubs(:create_account_on_new_pds).raises(
      GoatService::AccountExistsError,
      "Orphaned deactivated account exists"
    )
    GoatService.stubs(:new).returns(service)

    # Should not retry AccountExistsError
    job.perform(@migration.id)

    @migration.reload
    assert @migration.failed?
    assert @migration.last_error.include?("Orphaned deactivated account")
  end

  test "CreateAccountJob handles RateLimitError with extended retry" do
    job = CreateAccountJob.new
    service = mock('goat_service')
    service.stubs(:login_old_pds).raises(
      GoatService::RateLimitError,
      "PDS rate limit exceeded"
    )
    GoatService.stubs(:new).returns(service)

    # Mock retry with polynomial backoff
    job.expects(:retry_job).with(wait: anything, queue: :migrations)

    assert_raises(GoatService::RateLimitError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.last_error.include?("rate limit")
  end

  test "CreateAccountJob verifies existing account for migration_in" do
    @migration.update!(migration_type: :migration_in)

    job = CreateAccountJob.new
    service = mock('goat_service')
    service.expects(:verify_existing_account_access).returns(
      { exists: true, deactivated: true }
    )
    service.expects(:activate_account).never # Should not activate in CreateAccountJob
    GoatService.stubs(:new).returns(service)

    # Should transition to pending_repo for migration_in
    @migration.expects(:advance_to_pending_repo!)

    job.perform(@migration.id)
  end

  test "CreateAccountJob fails migration_in when account doesn't exist" do
    @migration.update!(migration_type: :migration_in)

    job = CreateAccountJob.new
    service = mock('goat_service')
    service.stubs(:verify_existing_account_access).raises(
      GoatService::GoatError,
      "Account does not exist on target PDS"
    )
    GoatService.stubs(:new).returns(service)

    job.stubs(:retry_job).raises(Sidekiq::JobRetry::Skip)

    assert_raises(Sidekiq::JobRetry::Skip) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.failed?
    assert @migration.last_error.include?("does not exist")
  end

  # ============================================================================
  # ImportRepoJob - Stage 3 Errors
  # ============================================================================

  test "ImportRepoJob handles timeout error with retry" do
    @migration.update!(status: :pending_repo)

    job = ImportRepoJob.new
    service = mock('goat_service')
    service.stubs(:export_repo).raises(
      GoatService::TimeoutError,
      "Repository export timed out after 600 seconds"
    )
    GoatService.stubs(:new).returns(service)

    job.expects(:retry_job).with(wait: anything, queue: :migrations)

    assert_raises(GoatService::TimeoutError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.last_error.include?("timed out")
  end

  test "ImportRepoJob handles CAR file corruption with retry" do
    @migration.update!(status: :pending_repo)

    job = ImportRepoJob.new
    service = mock('goat_service')
    service.stubs(:export_repo).raises(
      GoatService::GoatError,
      "Repository export failed: file not created or empty"
    )
    GoatService.stubs(:new).returns(service)

    job.expects(:retry_job)

    assert_raises(GoatService::GoatError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.last_error.include?("file not created or empty")
  end

  test "ImportRepoJob converts legacy blobs if enabled" do
    @migration.update!(status: :pending_repo)
    ENV['CONVERT_LEGACY_BLOBS'] = 'true'

    job = ImportRepoJob.new
    service = mock('goat_service')
    car_path = '/tmp/account.car'
    converted_path = '/tmp/account_converted.car'

    service.expects(:export_repo).returns(car_path)
    service.expects(:convert_legacy_blobs_if_needed).with(car_path).returns(converted_path)
    service.expects(:import_repo).with(converted_path)
    GoatService.stubs(:new).returns(service)

    @migration.expects(:advance_to_pending_blobs!)

    job.perform(@migration.id)
  ensure
    ENV.delete('CONVERT_LEGACY_BLOBS')
  end

  # ============================================================================
  # ImportBlobsJob - Stage 4 Errors (Most Complex)
  # ============================================================================

  test "ImportBlobsJob respects concurrency limit and re-enqueues" do
    @migration.update!(status: :pending_blobs)

    # Create 15 migrations already in blob import stage
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

    job = ImportBlobsJob.new

    # Should re-enqueue with delay instead of executing
    ImportBlobsJob.expects(:perform_in).with(30.seconds, @migration.id)

    job.perform(@migration.id)

    # Migration should still be pending_blobs
    @migration.reload
    assert @migration.pending_blobs?
  end

  test "ImportBlobsJob handles individual blob download failure" do
    @migration.update!(status: :pending_blobs)

    job = ImportBlobsJob.new
    service = mock('goat_service')

    # Mock blob listing
    service.stubs(:list_blobs).returns({
      'cids' => ['blob1', 'blob2', 'blob3'],
      'cursor' => nil
    })

    # blob1 succeeds
    service.stubs(:download_blob).with('blob1').returns('/tmp/blob1')
    service.stubs(:upload_blob).with('/tmp/blob1').returns({ 'blob' => {} })

    # blob2 fails all retries
    service.stubs(:download_blob).with('blob2').raises(
      GoatService::NetworkError,
      "Failed to download blob"
    ).times(3)

    # blob3 succeeds
    service.stubs(:download_blob).with('blob3').returns('/tmp/blob3')
    service.stubs(:upload_blob).with('/tmp/blob3').returns({ 'blob' => {} })

    GoatService.stubs(:new).returns(service)

    @migration.expects(:advance_to_pending_prefs!)

    job.perform(@migration.id)

    @migration.reload
    # Should have logged failed blob
    assert @migration.progress_data['failed_blobs'].include?('blob2')
  end

  test "ImportBlobsJob handles blob rate limiting with extended retry" do
    @migration.update!(status: :pending_blobs)

    job = ImportBlobsJob.new
    service = mock('goat_service')

    service.stubs(:list_blobs).returns({
      'cids' => ['blob1'],
      'cursor' => nil
    })

    # First attempt: rate limited
    # Second attempt: succeeds
    call_count = 0
    service.stubs(:download_blob).with('blob1').returns do
      call_count += 1
      if call_count == 1
        raise GoatService::RateLimitError, "Rate limit exceeded"
      else
        '/tmp/blob1'
      end
    end

    service.stubs(:upload_blob).with('/tmp/blob1').returns({ 'blob' => {} })

    GoatService.stubs(:new).returns(service)

    @migration.expects(:advance_to_pending_prefs!)

    job.perform(@migration.id)

    assert_equal 2, call_count
  end

  test "ImportBlobsJob writes failed blobs manifest" do
    @migration.update!(status: :pending_blobs)

    job = ImportBlobsJob.new
    service = mock('goat_service')

    service.stubs(:list_blobs).returns({
      'cids' => ['blob1', 'blob2'],
      'cursor' => nil
    })

    # Both blobs fail
    service.stubs(:download_blob).raises(GoatService::NetworkError, "Failed").times(6)

    GoatService.stubs(:new).returns(service)

    @migration.expects(:advance_to_pending_prefs!)

    job.perform(@migration.id)

    @migration.reload
    manifest_path = service.work_dir.join('FAILED_BLOB_UPLOADS.txt')
    assert File.exist?(manifest_path)
    manifest_content = File.read(manifest_path)
    assert manifest_content.include?('blob1')
    assert manifest_content.include?('blob2')
  end

  test "ImportBlobsJob handles blob 404 by skipping blob" do
    @migration.update!(status: :pending_blobs)

    job = ImportBlobsJob.new
    service = mock('goat_service')

    service.stubs(:list_blobs).returns({
      'cids' => ['blob_deleted'],
      'cursor' => nil
    })

    # Blob not found (deleted from old PDS)
    service.stubs(:download_blob).with('blob_deleted').raises(
      GoatService::NetworkError,
      "Failed to download blob: 404"
    )

    GoatService.stubs(:new).returns(service)

    @migration.expects(:advance_to_pending_prefs!)

    job.perform(@migration.id)

    @migration.reload
    # Should skip and continue
    assert @migration.progress_data['failed_blobs'].include?('blob_deleted')
  end

  test "ImportBlobsJob tracks blob upload progress" do
    @migration.update!(status: :pending_blobs)

    job = ImportBlobsJob.new
    service = mock('goat_service')

    blob_size = 1024000
    service.stubs(:list_blobs).returns({
      'cids' => ['blob1'],
      'cursor' => nil
    })
    service.stubs(:download_blob).returns('/tmp/blob1')
    service.stubs(:upload_blob).returns({ 'blob' => {} })

    # Mock File.size to return blob size
    File.stubs(:size).with('/tmp/blob1').returns(blob_size)

    GoatService.stubs(:new).returns(service)

    @migration.expects(:update_blob_progress!).with(
      cid: 'blob1',
      size: blob_size,
      uploaded: blob_size
    )

    @migration.expects(:advance_to_pending_prefs!)

    job.perform(@migration.id)
  end

  # ============================================================================
  # ImportPrefsJob - Stage 5 Errors
  # ============================================================================

  test "ImportPrefsJob continues migration on non-critical failure" do
    @migration.update!(status: :pending_prefs)

    job = ImportPrefsJob.new
    service = mock('goat_service')

    service.stubs(:export_preferences).raises(
      GoatService::GoatError,
      "Failed to export preferences"
    )

    GoatService.stubs(:new).returns(service)

    # Should log warning but continue
    job.expects(:retry_job).with(wait: anything, queue: :migrations)

    assert_raises(GoatService::GoatError) do
      job.perform(@migration.id)
    end
  end

  test "ImportPrefsJob handles unsupported preferences format" do
    @migration.update!(status: :pending_prefs)

    job = ImportPrefsJob.new
    service = mock('goat_service')
    prefs_path = '/tmp/prefs.json'

    service.stubs(:export_preferences).returns(prefs_path)
    service.stubs(:import_preferences).raises(
      GoatService::GoatError,
      "New PDS doesn't support some preferences"
    )

    GoatService.stubs(:new).returns(service)

    job.expects(:retry_job)

    assert_raises(GoatService::GoatError) do
      job.perform(@migration.id)
    end
  end

  # ============================================================================
  # WaitForPlcTokenJob - Stage 6 Errors
  # ============================================================================

  test "WaitForPlcTokenJob requests PLC token and generates OTP" do
    @migration.update!(status: :pending_plc)

    job = WaitForPlcTokenJob.new
    service = mock('goat_service')
    service.expects(:request_plc_token)
    GoatService.stubs(:new).returns(service)

    @migration.expects(:generate_plc_otp!)

    job.perform(@migration.id)

    # Should remain in pending_plc state
    @migration.reload
    assert @migration.pending_plc?
  end

  test "WaitForPlcTokenJob handles PLC token request failure" do
    @migration.update!(status: :pending_plc)

    job = WaitForPlcTokenJob.new
    service = mock('goat_service')
    service.stubs(:request_plc_token).raises(
      GoatService::GoatError,
      "Failed to request PLC token"
    )
    GoatService.stubs(:new).returns(service)

    job.expects(:retry_job)

    assert_raises(GoatService::GoatError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.last_error.include?("Failed to request PLC token")
  end

  # ============================================================================
  # UpdatePlcJob - Stage 7 Errors (CRITICAL)
  # ============================================================================

  test "UpdatePlcJob fails immediately when PLC token missing" do
    @migration.update!(
      status: :pending_plc,
      encrypted_plc_token: nil
    )

    job = UpdatePlcJob.new

    # Should not retry on missing token
    job.perform(@migration.id)

    @migration.reload
    assert @migration.failed?
    assert @migration.last_error.include?("PLC token missing or expired")
  end

  test "UpdatePlcJob fails immediately when PLC token expired" do
    @migration.update!(
      status: :pending_plc,
      credentials_expires_at: 1.hour.ago
    )
    @migration.set_plc_token("expired-token")
    @migration.update!(credentials_expires_at: 1.hour.ago)

    job = UpdatePlcJob.new

    job.perform(@migration.id)

    @migration.reload
    assert @migration.failed?
    assert @migration.last_error.include?("PLC token missing or expired")
  end

  test "UpdatePlcJob handles PLC operation signing failure" do
    @migration.update!(status: :pending_plc)
    @migration.set_plc_token("valid-token")

    job = UpdatePlcJob.new
    service = mock('goat_service')
    service.stubs(:get_recommended_plc_operation).returns('/tmp/unsigned.json')
    service.stubs(:sign_plc_operation).raises(
      GoatService::GoatError,
      "Failed to sign PLC operation"
    )
    GoatService.stubs(:new).returns(service)

    # Should retry once for critical operation
    job.expects(:retry_job).with(wait: 30, queue: :critical)

    assert_raises(GoatService::GoatError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.last_error.include?("Failed to sign PLC operation")
  end

  test "UpdatePlcJob handles PLC submission failure with retry" do
    @migration.update!(status: :pending_plc)
    @migration.set_plc_token("valid-token")

    job = UpdatePlcJob.new
    service = mock('goat_service')
    service.stubs(:get_recommended_plc_operation).returns('/tmp/unsigned.json')
    service.stubs(:sign_plc_operation).returns('/tmp/signed.json')
    service.stubs(:submit_plc_operation).raises(
      GoatService::GoatError,
      "Failed to submit PLC operation"
    )
    GoatService.stubs(:new).returns(service)

    job.expects(:retry_job).with(wait: 30, queue: :critical)

    assert_raises(GoatService::GoatError) do
      job.perform(@migration.id)
    end
  end

  test "UpdatePlcJob handles rate limiting with polynomial backoff" do
    @migration.update!(status: :pending_plc)
    @migration.set_plc_token("valid-token")

    job = UpdatePlcJob.new
    service = mock('goat_service')
    service.stubs(:get_recommended_plc_operation).returns('/tmp/unsigned.json')
    service.stubs(:sign_plc_operation).returns('/tmp/signed.json')
    service.stubs(:submit_plc_operation).raises(
      GoatService::RateLimitError,
      "PLC directory rate-limited"
    )
    GoatService.stubs(:new).returns(service)

    # Should use longer retry for rate limiting
    job.expects(:retry_job).with(wait: anything, queue: :critical)

    assert_raises(GoatService::RateLimitError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.last_error.include?("rate-limited")
  end

  test "UpdatePlcJob transitions to pending_activation on success" do
    @migration.update!(status: :pending_plc)
    @migration.set_plc_token("valid-token")

    job = UpdatePlcJob.new
    service = mock('goat_service')
    service.stubs(:get_recommended_plc_operation).returns('/tmp/unsigned.json')
    service.stubs(:sign_plc_operation).returns('/tmp/signed.json')
    service.stubs(:submit_plc_operation)
    GoatService.stubs(:new).returns(service)

    @migration.expects(:advance_to_pending_activation!)

    job.perform(@migration.id)
  end

  # ============================================================================
  # ActivateAccountJob - Stage 8 Errors
  # ============================================================================

  test "ActivateAccountJob handles new account activation failure" do
    @migration.update!(status: :pending_activation)

    job = ActivateAccountJob.new
    service = mock('goat_service')
    service.stubs(:activate_account).raises(
      GoatService::GoatError,
      "Failed to activate new account"
    )
    GoatService.stubs(:new).returns(service)

    job.expects(:retry_job)

    assert_raises(GoatService::GoatError) do
      job.perform(@migration.id)
    end

    @migration.reload
    assert @migration.last_error.include?("Failed to activate new account")
  end

  test "ActivateAccountJob handles old account deactivation failure gracefully" do
    @migration.update!(status: :pending_activation)

    job = ActivateAccountJob.new
    service = mock('goat_service')
    service.expects(:activate_account) # Succeeds
    service.stubs(:deactivate_account).raises(
      GoatService::GoatError,
      "Failed to deactivate old account"
    )
    GoatService.stubs(:new).returns(service)

    # Should complete migration despite deactivation failure
    # But log the issue
    @migration.expects(:mark_complete!)

    job.perform(@migration.id)

    @migration.reload
    assert @migration.completed?
  end

  test "ActivateAccountJob cleans up credentials on success" do
    @migration.update!(status: :pending_activation)
    @migration.set_password("test_password")
    @migration.set_plc_token("test_token")

    job = ActivateAccountJob.new
    service = mock('goat_service')
    service.expects(:activate_account)
    service.expects(:deactivate_account)
    GoatService.stubs(:new).returns(service)

    @migration.expects(:clear_credentials!)
    @migration.expects(:mark_complete!)

    job.perform(@migration.id)

    @migration.reload
    assert @migration.completed?
  end

  test "ActivateAccountJob sends completion email" do
    @migration.update!(status: :pending_activation)

    job = ActivateAccountJob.new
    service = mock('goat_service')
    service.expects(:activate_account)
    service.expects(:deactivate_account)
    GoatService.stubs(:new).returns(service)

    @migration.stubs(:clear_credentials!)
    @migration.stubs(:mark_complete!)

    # Should send completion email
    MigrationMailer.expects(:migration_complete).with(@migration).returns(
      mock(deliver_later: true)
    )

    job.perform(@migration.id)
  end

  # ============================================================================
  # Cleanup & Resource Management
  # ============================================================================

  test "Jobs clean up work directory on completion" do
    @migration.update!(status: :pending_activation)

    job = ActivateAccountJob.new
    service = mock('goat_service')
    service.expects(:activate_account)
    service.expects(:deactivate_account)
    service.expects(:cleanup) # Should call cleanup
    GoatService.stubs(:new).returns(service)

    @migration.stubs(:clear_credentials!)
    @migration.stubs(:mark_complete!)
    MigrationMailer.stubs(:migration_complete).returns(mock(deliver_later: true))

    job.perform(@migration.id)
  end

  test "Jobs clean up work directory on failure after max retries" do
    @migration.update!(status: :pending_activation)

    job = ActivateAccountJob.new
    service = mock('goat_service')
    service.stubs(:activate_account).raises(GoatService::GoatError, "Failure")
    service.expects(:cleanup) # Should call cleanup even on failure
    GoatService.stubs(:new).returns(service)

    job.stubs(:retry_job).raises(Sidekiq::JobRetry::Skip)

    assert_raises(Sidekiq::JobRetry::Skip) do
      job.perform(@migration.id)
    end
  end
end
