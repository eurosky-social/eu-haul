require "test_helper"

# ImportBlobsJob Blob Reconciliation Tests
# Tests for the reconcile_blobs step in ImportBlobsJob that runs after the
# initial blob import. Reconciliation compares expected vs imported blob counts
# via get_account_status, then fetches and uploads any missing blobs.
# The reconciliation is best-effort: failures are logged but do not fail
# the migration.
class BlobReconciliationTest < ActiveSupport::TestCase
  def setup
    @migration = migrations(:pending_blobs)
    @migration.set_password("test_password_123")
    @migration.save!
  end

  # ============================================================================
  # Reconciliation runs after blob import
  # ============================================================================

  test "reconciliation runs after blob import" do
    service = mock('goat_service')
    service.stubs(:login_new_pds).returns(true)

    # Stub blob listing to return no blobs (simplest case)
    service.stubs(:list_blobs).returns({ 'cids' => [], 'cursor' => nil })

    # Expect reconciliation methods to be called
    service.expects(:get_account_status).returns({
      'expectedBlobs' => 0,
      'importedBlobs' => 0
    })

    GoatService.stubs(:new).returns(service)

    job = ImportBlobsJob.new
    job.perform(@migration.id)

    @migration.reload
    assert @migration.pending_prefs?
    assert_equal 'complete', @migration.progress_data['reconciliation_status']
  end

  # ============================================================================
  # Reconciliation fills missing blobs
  # ============================================================================

  test "reconciliation fills missing blobs" do
    service = mock('goat_service')
    service.stubs(:login_new_pds).returns(true)

    # No blobs in initial listing
    service.stubs(:list_blobs).returns({ 'cids' => [], 'cursor' => nil })

    # Account status shows mismatch
    service.expects(:get_account_status).returns({
      'expectedBlobs' => 3,
      'importedBlobs' => 1
    })

    # Missing blobs query returns 2 CIDs
    service.expects(:collect_all_missing_blobs).returns(['bafymissing1', 'bafymissing2'])

    # Download and upload each missing blob
    service.expects(:download_blob).with('bafymissing1').returns('/tmp/blob_missing1')
    service.expects(:upload_blob).with('/tmp/blob_missing1').returns({ 'blob' => {} })

    service.expects(:download_blob).with('bafymissing2').returns('/tmp/blob_missing2')
    service.expects(:upload_blob).with('/tmp/blob_missing2').returns({ 'blob' => {} })

    # Stub FileUtils.rm_f for cleanup and File.size
    File.stubs(:size).with('/tmp/blob_missing1').returns(2048)
    File.stubs(:size).with('/tmp/blob_missing2').returns(4096)
    FileUtils.stubs(:rm_f)

    GoatService.stubs(:new).returns(service)

    job = ImportBlobsJob.new
    job.perform(@migration.id)

    @migration.reload
    assert @migration.pending_prefs?
    assert_equal 'complete', @migration.progress_data['reconciliation_status']
    assert_equal 2, @migration.progress_data['reconciliation_recovered']
    assert_equal 3, @migration.progress_data['reconciliation_expected_blobs']
    assert_equal 1, @migration.progress_data['reconciliation_imported_blobs']
    assert_equal 2, @migration.progress_data['reconciliation_missing_count']
  end

  # ============================================================================
  # Reconciliation is best-effort
  # ============================================================================

  test "reconciliation is best-effort when get_account_status fails" do
    service = mock('goat_service')
    service.stubs(:login_new_pds).returns(true)

    # No blobs in initial listing
    service.stubs(:list_blobs).returns({ 'cids' => [], 'cursor' => nil })

    # Account status raises error
    service.expects(:get_account_status).raises(
      GoatService::GoatError, "Failed to get account status"
    )

    GoatService.stubs(:new).returns(service)

    job = ImportBlobsJob.new
    job.perform(@migration.id)

    # Migration should still complete successfully
    @migration.reload
    assert @migration.pending_prefs?
    assert_equal 'skipped', @migration.progress_data['reconciliation_status']
    assert_match /Account status check failed/, @migration.progress_data['reconciliation_error']
  end

  # ============================================================================
  # Reconciliation skips when counts match
  # ============================================================================

  test "reconciliation skips when counts match" do
    service = mock('goat_service')
    service.stubs(:login_new_pds).returns(true)

    # No blobs in initial listing
    service.stubs(:list_blobs).returns({ 'cids' => [], 'cursor' => nil })

    # Account status shows matching counts
    service.expects(:get_account_status).returns({
      'expectedBlobs' => 5,
      'importedBlobs' => 5
    })

    # collect_all_missing_blobs should NOT be called when counts match
    service.expects(:collect_all_missing_blobs).never

    GoatService.stubs(:new).returns(service)

    job = ImportBlobsJob.new
    job.perform(@migration.id)

    @migration.reload
    assert @migration.pending_prefs?
    assert_equal 'complete', @migration.progress_data['reconciliation_status']
    assert @migration.progress_data['reconciliation_completed_at'].present?
  end

  # ============================================================================
  # Reconciliation tracks failed blobs
  # ============================================================================

  test "reconciliation tracks failed blobs" do
    service = mock('goat_service')
    service.stubs(:login_new_pds).returns(true)

    # No blobs in initial listing
    service.stubs(:list_blobs).returns({ 'cids' => [], 'cursor' => nil })

    # Account status shows mismatch
    service.expects(:get_account_status).returns({
      'expectedBlobs' => 3,
      'importedBlobs' => 0
    })

    # Missing blobs query returns 3 CIDs
    service.expects(:collect_all_missing_blobs).returns(
      ['bafyok1', 'bafyfail1', 'bafyfail2']
    )

    # First blob succeeds
    service.expects(:download_blob).with('bafyok1').returns('/tmp/blob_ok1')
    service.expects(:upload_blob).with('/tmp/blob_ok1').returns({ 'blob' => {} })
    File.stubs(:size).with('/tmp/blob_ok1').returns(1024)

    # Second blob fails on download
    service.expects(:download_blob).with('bafyfail1').raises(
      GoatService::NetworkError, "Failed to download blob"
    )

    # Third blob fails on upload
    service.expects(:download_blob).with('bafyfail2').returns('/tmp/blob_fail2')
    service.expects(:upload_blob).with('/tmp/blob_fail2').raises(
      GoatService::NetworkError, "Failed to upload blob"
    )
    File.stubs(:size).with('/tmp/blob_fail2').returns(2048)

    FileUtils.stubs(:rm_f)

    GoatService.stubs(:new).returns(service)

    job = ImportBlobsJob.new
    job.perform(@migration.id)

    @migration.reload
    assert @migration.pending_prefs?
    assert_equal 'partial', @migration.progress_data['reconciliation_status']
    assert_equal 1, @migration.progress_data['reconciliation_recovered']

    # Failed blobs should be tracked in both reconciliation and overall failed_blobs
    still_missing = @migration.progress_data['reconciliation_still_missing']
    assert_includes still_missing, 'bafyfail1'
    assert_includes still_missing, 'bafyfail2'

    failed_blobs = @migration.progress_data['failed_blobs']
    assert_includes failed_blobs, 'bafyfail1'
    assert_includes failed_blobs, 'bafyfail2'
  end
end
