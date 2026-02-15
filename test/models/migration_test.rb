require "test_helper"

# Migration Model Tests
# Tests based on MIGRATION_ERROR_ANALYSIS.md covering all error scenarios
class MigrationTest < ActiveSupport::TestCase
  def setup
    @valid_attributes = {
      did: "did:plc:abc123xyz",
      old_handle: "user.oldpds.com",
      new_handle: "user.newpds.com",
      old_pds_host: "https://oldpds.com",
      new_pds_host: "https://newpds.com",
      email: "user@example.com",
      migration_type: "migration_out"
    }
  end

  # ============================================================================
  # Validations
  # ============================================================================

  test "valid migration attributes" do
    migration = Migration.new(@valid_attributes)
    migration.set_password("test_password_123")
    assert migration.valid?, "Migration should be valid with all required attributes"
  end

  test "requires did" do
    migration = Migration.new(@valid_attributes.except(:did))
    assert_not migration.valid?
    assert_includes migration.errors[:did], "can't be blank"
  end

  test "validates did format" do
    migration = Migration.new(@valid_attributes.merge(did: "invalid-did"))
    assert_not migration.valid?
    assert_includes migration.errors[:did], "is invalid"
  end

  test "requires email" do
    migration = Migration.new(@valid_attributes.except(:email))
    assert_not migration.valid?
    assert_includes migration.errors[:email], "can't be blank"
  end

  test "validates email format" do
    migration = Migration.new(@valid_attributes.merge(email: "invalid-email"))
    assert_not migration.valid?
    assert_includes migration.errors[:email], "is invalid"
  end

  test "validates handle format" do
    invalid_handles = [
      "no_dots",                    # No dots
      "-starts-with-hyphen.com",    # Starts with hyphen
      "ends-with-hyphen-.com",      # Ends with hyphen
      "label-too-long-" + "a" * 64 + ".com", # Label > 63 chars
      "a" * 254 + ".com"            # Total > 253 chars
    ]

    invalid_handles.each do |handle|
      migration = Migration.new(@valid_attributes.merge(old_handle: handle))
      assert_not migration.valid?, "Should reject invalid handle: #{handle}"
    end
  end

  test "generates unique token on creation" do
    migration1 = Migration.create!(@valid_attributes.merge(password: "test"))
    migration2 = Migration.create!(@valid_attributes.merge(
      did: "did:plc:different",
      password: "test"
    ))

    assert_not_equal migration1.token, migration2.token
    assert_match /\AEURO-[A-Z0-9]{16}\z/, migration1.token
    assert_match /\AEURO-[A-Z0-9]{16}\z/, migration2.token
  end

  test "prevents concurrent active migrations for same DID" do
    Migration.create!(@valid_attributes.merge(
      status: :pending_account,
      password: "test"
    ))

    duplicate_migration = Migration.new(@valid_attributes.merge(password: "test"))
    assert_not duplicate_migration.valid?
    assert duplicate_migration.errors[:did].any? { |msg| msg.include?("already has an active migration in progress") }
  end

  test "allows new migration after previous completed" do
    Migration.create!(@valid_attributes.merge(
      status: :completed,
      password: "test"
    ))

    new_migration = Migration.new(@valid_attributes.merge(password: "test"))
    assert new_migration.valid?, "Should allow migration after previous completed"
  end

  test "allows new migration after previous failed" do
    Migration.create!(@valid_attributes.merge(
      status: :failed,
      password: "test"
    ))

    new_migration = Migration.new(@valid_attributes.merge(password: "test"))
    assert new_migration.valid?, "Should allow migration after previous failed"
  end

  # ============================================================================
  # Stage 1: Email Verification
  # Error: Email delivery failure, expired verification link, invalid token
  # ============================================================================

  test "generates email verification code on creation" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    assert migration.email_verification_token.present?
    assert_match /\A[A-Z0-9]{3}-[A-Z0-9]{3}\z/, migration.email_verification_token
  end

  test "email verification token is unique" do
    migration1 = Migration.create!(@valid_attributes.merge(password: "test"))
    migration2 = Migration.create!(@valid_attributes.merge(
      did: "did:plc:different",
      password: "test"
    ))

    assert_not_equal migration1.email_verification_token,
      migration2.email_verification_token
  end

  test "verify_email! with valid token marks email as verified" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    token = migration.email_verification_token

    assert migration.send(:verify_email!, token)
    migration.reload
    assert migration.email_verified_at.present?
    assert_nil migration.email_verification_token
  end

  test "verify_email! with invalid token fails" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))

    assert_not migration.send(:verify_email!, "invalid-token")
    migration.reload
    assert_nil migration.email_verified_at
    assert migration.email_verification_token.present?
  end

  test "email_verified? returns correct status" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    assert_not migration.send(:email_verified?)

    migration.update!(email_verified_at: Time.current)
    assert migration.send(:email_verified?)
  end

  # ============================================================================
  # Stage 2: Create Account
  # Errors: Auth failure, network errors, account exists, rate limiting,
  #         credentials expired, invite code issues
  # ============================================================================

  test "credentials_expired? when credentials_expires_at is nil" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    migration.update!(credentials_expires_at: nil)
    assert migration.credentials_expired?
  end

  test "credentials_expired? when credentials_expires_at in past" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    migration.update!(credentials_expires_at: 1.hour.ago)
    assert migration.credentials_expired?
  end

  test "credentials_expired? when credentials_expires_at in future" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    migration.update!(credentials_expires_at: 1.hour.from_now)
    assert_not migration.credentials_expired?
  end

  test "set_password encrypts and sets expiration" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    migration.set_password("new_password", expires_in: 24.hours)

    assert migration.encrypted_password.present?
    assert migration.credentials_expires_at > Time.current
    assert migration.credentials_expires_at <= 24.hours.from_now
  end

  test "password getter returns nil when credentials expired" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    migration.set_password("secure_password")
    migration.update!(credentials_expires_at: 1.hour.ago)

    assert_nil migration.password
  end

  test "invite_code_expired? when invite_code_expires_at in past" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    migration.set_invite_code("test-invite")
    migration.update!(invite_code_expires_at: 1.hour.ago)

    assert migration.invite_code_expired?
  end

  test "invite_code getter returns nil when expired" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    migration.set_invite_code("test-invite")
    migration.update!(invite_code_expires_at: 1.hour.ago)

    assert_nil migration.invite_code
  end

  test "mark_failed! updates status and error message" do
    migration = Migration.create!(@valid_attributes.merge(
      status: :pending_account,
      password: "test"
    ))

    error = StandardError.new("Authentication failed")
    migration.mark_failed!(error)

    assert migration.failed?
    assert_equal "Authentication failed", migration.last_error
    assert_equal 1, migration.retry_count
  end

  test "job retry tracking" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    migration.start_job_attempt!("CreateAccountJob", 3, 1)

    assert_equal "CreateAccountJob", migration.current_job_step
    assert_equal 1, migration.current_job_attempt
    assert_equal 3, migration.current_job_max_attempts
    assert_equal 2, migration.job_attempts_remaining

    migration.increment_job_attempt!
    assert_equal 2, migration.current_job_attempt
    assert_equal 1, migration.job_attempts_remaining
    assert migration.job_retrying?
  end

  # ============================================================================
  # Stage 3: Import Repository
  # Errors: Timeout, network error, CAR corruption, disk space, rate limiting
  # ============================================================================

  test "advance_to_pending_repo! transitions state and enqueues job" do
    migration = Migration.create!(@valid_attributes.merge(
      status: :account_created,
      password: "test"
    ))

    assert_enqueued_with(job: ImportRepoJob, args: [migration.id]) do
      migration.advance_to_pending_repo!
    end

    assert migration.pending_repo?
  end

  # ============================================================================
  # Stage 4: Import Blobs (Most Complex)
  # Errors: Concurrency limits, blob download/upload failures, rate limiting,
  #         memory exhaustion, partial failures
  # ============================================================================

  test "update_blob_progress! tracks individual blob progress" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))

    migration.update_blob_progress!(
      cid: "bafybeiabc123",
      size: 1024000,
      uploaded: 512000
    )

    blob_data = migration.progress_data['blobs']['bafybeiabc123']
    assert_equal 1024000, blob_data['size']
    assert_equal 512000, blob_data['uploaded']
    assert blob_data['updated_at'].present?
  end

  test "progress_percentage during blob upload" do
    migration = Migration.create!(@valid_attributes.merge(
      status: :pending_blobs,
      password: "test"
    ))

    # No blobs uploaded yet
    base_percentage = migration.progress_percentage
    assert base_percentage >= 20

    # Simulate partial blob upload
    migration.update_blob_progress!(cid: "blob1", size: 1000, uploaded: 500)
    migration.update_blob_progress!(cid: "blob2", size: 1000, uploaded: 1000)

    percentage = migration.progress_percentage
    assert percentage > base_percentage
    assert percentage < 70 # Should be between blob start and prefs stage
  end

  test "estimated_time_remaining calculates based on upload rate" do
    migration = Migration.create!(@valid_attributes.merge(
      status: :pending_blobs,
      password: "test"
    ))

    # Add blobs with timestamps
    now = Time.current
    migration.progress_data['blobs'] = {
      'blob1' => { 'size' => 10000, 'uploaded' => 10000, 'updated_at' => (now - 10.seconds).iso8601 },
      'blob2' => { 'size' => 10000, 'uploaded' => 5000, 'updated_at' => now.iso8601 },
      'blob3' => { 'size' => 10000, 'uploaded' => 0, 'updated_at' => now.iso8601 }
    }
    migration.save!

    # Total: 30000 bytes, uploaded: 15000 bytes in 10 seconds
    # Rate: 1500 bytes/sec, remaining: 15000 bytes
    # Estimate: 10 seconds
    estimate = migration.estimated_time_remaining
    assert_not_nil estimate
    assert estimate > 0
  end

  test "can_cancel? returns false during critical stages" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))

    # Can cancel during early stages
    migration.update!(status: :pending_account)
    assert migration.can_cancel?

    migration.update!(status: :pending_blobs)
    assert migration.can_cancel?

    # Cannot cancel during PLC stage
    migration.update!(status: :pending_plc)
    assert_not migration.can_cancel?

    # Cannot cancel during activation
    migration.update!(status: :pending_activation)
    assert_not migration.can_cancel?

    # Cannot cancel after completion
    migration.update!(status: :completed)
    assert_not migration.can_cancel?
  end

  test "cancel! marks migration as failed when allowed" do
    migration = Migration.create!(@valid_attributes.merge(
      status: :pending_blobs,
      password: "test"
    ))

    assert migration.cancel!
    assert migration.failed?
    assert migration.last_error.include?("cancelled by user")
  end

  test "cancel! returns false during critical stages" do
    migration = Migration.create!(@valid_attributes.merge(
      status: :pending_plc,
      password: "test"
    ))

    assert_not migration.cancel!
    assert migration.pending_plc? # Status unchanged
  end

  # ============================================================================
  # Stage 5: Import Preferences
  # Errors: Export/import failure, auth failure, invalid format
  # ============================================================================

  test "advance_to_pending_prefs! transitions state" do
    migration = Migration.create!(@valid_attributes.merge(
      status: :pending_blobs,
      password: "test"
    ))

    assert_enqueued_with(job: ImportPrefsJob, args: [migration.id]) do
      migration.advance_to_pending_prefs!
    end

    assert migration.pending_prefs?
  end

  # ============================================================================
  # Stage 6: Wait for PLC Token
  # Errors: Token request failure, email delivery failure, OTP expired,
  #         too many attempts, token format invalid
  # ============================================================================

  test "generate_plc_otp! creates 6-digit code with expiration" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))

    otp = migration.generate_plc_otp!(expires_in: 15.minutes)

    assert_equal 6, otp.length
    assert otp.match?(/\A\d{6}\z/)
    assert migration.plc_otp_expires_at > Time.current
    assert migration.plc_otp_expires_at <= 15.minutes.from_now
    assert_equal 0, migration.plc_otp_attempts
  end

  test "verify_plc_otp with valid code succeeds" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    otp = migration.generate_plc_otp!

    result = migration.verify_plc_otp(otp)

    assert result[:valid]
    assert_nil migration.reload.encrypted_plc_otp
    assert_nil migration.plc_otp_expires_at
    assert_equal 0, migration.plc_otp_attempts
  end

  test "verify_plc_otp with invalid code fails and increments attempts" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    migration.generate_plc_otp!

    result = migration.verify_plc_otp("000000")

    assert_not result[:valid]
    assert result[:error].include?("Invalid OTP")
    assert_equal 1, migration.reload.plc_otp_attempts
  end

  test "verify_plc_otp rejects expired OTP" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    otp = migration.generate_plc_otp!
    migration.update!(plc_otp_expires_at: 1.minute.ago)

    result = migration.verify_plc_otp(otp)

    assert_not result[:valid]
    assert result[:error].include?("expired")
  end

  test "verify_plc_otp rate limits after 5 failed attempts" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    migration.generate_plc_otp!

    # Fail 5 times
    5.times { migration.verify_plc_otp("000000") }

    # 6th attempt should be rate limited
    result = migration.verify_plc_otp("000000")

    assert_not result[:valid]
    assert result[:error].include?("Too many failed attempts")
  end

  test "set_plc_token encrypts token with expiration" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    migration.set_plc_token("plc-token-abc123", expires_in: 1.hour)

    assert migration.encrypted_plc_token.present?
    assert migration.credentials_expires_at > Time.current
    assert migration.credentials_expires_at <= 1.hour.from_now
  end

  test "plc_token getter returns nil when credentials expired" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    migration.set_plc_token("plc-token-abc123")
    migration.update!(credentials_expires_at: 1.hour.ago)

    assert_nil migration.plc_token
  end

  test "set_rotation_key encrypts rotation key" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    private_key = "z42tk" + "a" * 50

    migration.set_rotation_key(private_key)

    assert migration.rotation_private_key_ciphertext.present?
    # Note: rotation_key doesn't expire
  end

  # ============================================================================
  # Stage 7: Update PLC (CRITICAL - Point of No Return)
  # Errors: Missing/expired token, signing failure, submission failure,
  #         rate limiting, network errors, invalid operation
  # ============================================================================

  test "advance_to_pending_activation! transitions to critical stage" do
    migration = Migration.create!(@valid_attributes.merge(
      status: :pending_plc,
      password: "test"
    ))

    assert_enqueued_with(job: ActivateAccountJob, args: [migration.id]) do
      migration.advance_to_pending_activation!
    end

    assert migration.pending_activation?
  end

  # ============================================================================
  # Stage 8: Activate Account
  # Errors: Activation failure, old account deactivation failure, auth failure
  # ============================================================================

  test "mark_complete! clears errors and sets completed status" do
    migration = Migration.create!(@valid_attributes.merge(
      status: :pending_activation,
      last_error: "Some previous error",
      password: "test"
    ))

    migration.mark_complete!

    assert migration.completed?
    assert_nil migration.last_error
  end

  test "clear_credentials! removes all sensitive data" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    migration.set_password("secure_password")
    migration.set_plc_token("plc-token-abc")

    migration.clear_credentials!

    assert_nil migration.encrypted_password
    assert_nil migration.encrypted_plc_token
    assert_nil migration.credentials_expires_at
  end

  # ============================================================================
  # Backup Bundle Management (for downloadable backup mode)
  # ============================================================================

  test "set_backup_bundle_path sets path and expiration" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))
    path = "/tmp/test-bundle.tar.gz"

    migration.set_backup_bundle_path(path)

    assert_equal path, migration.backup_bundle_path
    assert migration.backup_created_at.present?
    assert migration.backup_expires_at > Time.current
    assert migration.backup_expires_at <= 24.hours.from_now
  end

  test "backup_expired? returns correct status" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))

    # No expiration set
    assert migration.backup_expired?

    # Future expiration
    migration.update!(backup_expires_at: 1.hour.from_now)
    assert_not migration.backup_expired?

    # Past expiration
    migration.update!(backup_expires_at: 1.hour.ago)
    assert migration.backup_expired?
  end

  # ============================================================================
  # Migration Type: migration_out vs migration_in
  # ============================================================================

  test "migration_out type helpers" do
    migration = Migration.create!(@valid_attributes.merge(
      migration_type: :migration_out,
      password: "test"
    ))

    assert migration.migration_out?
    assert migration.migrating_to_new_pds?
    assert_not migration.migration_in?
    assert_not migration.returning_to_existing_pds?
  end

  test "migration_in type helpers" do
    migration = Migration.create!(@valid_attributes.merge(
      migration_type: :migration_in,
      password: "test"
    ))

    assert migration.migration_in?
    assert migration.returning_to_existing_pds?
    assert_not migration.migration_out?
    assert_not migration.migrating_to_new_pds?
  end

  # ============================================================================
  # Progress Tracking
  # ============================================================================

  test "progress_percentage increases through migration stages" do
    migration = Migration.create!(@valid_attributes.merge(password: "test"))

    stages = [
      [:pending_account, 0],
      [:account_created, 10],
      [:pending_repo, 20],
      [:pending_prefs, 70],
      [:pending_plc, 80],
      [:pending_activation, 90],
      [:completed, 100]
    ]

    stages.each do |status, expected_min|
      migration.update!(status: status)
      percentage = migration.progress_percentage
      assert percentage >= expected_min,
        "Expected #{status} to be >= #{expected_min}%, got #{percentage}%"
    end
  end

  test "progress_percentage for failed migration" do
    migration = Migration.create!(@valid_attributes.merge(
      status: :failed,
      password: "test"
    ))

    assert_equal 0, migration.progress_percentage
  end
end
