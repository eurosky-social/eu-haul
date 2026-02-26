require "test_helper"

# MigrationErrorHelper.detect_error_type — exhaustive pattern-matching tests
#
# Every mark_failed! call site in the codebase produces an error message with a
# known prefix. These tests pin each message to the expected error type so that
# refactoring (or future i18n) cannot silently change the classification.
#
# HOW TO KEEP IN SYNC:
#   grep -rn 'mark_failed!' app/jobs app/controllers app/services \
#     | grep -oP '"[^"]*"' | sort -u
#   Compare the resulting list with ERROR_MESSAGES below.
#
class MigrationErrorHelperDetectErrorTypeTest < ActiveSupport::TestCase
  # ============================================================================
  # Canonical error messages — copied verbatim from mark_failed! call sites
  # ============================================================================

  # UpdatePlcJob — early-return checks (PLC directory NOT modified)
  PLC_TOKEN_EXPIRED_WITH_TIMESTAMP = 'PLC token has expired (expired at: 2026-02-26T12:00:00+00:00). Please request a new token.'
  PLC_TOKEN_MISSING                = 'PLC token is missing. Please request a new token.'
  PLC_CONFIRMATION_CODE_EXPIRED    = 'PLC confirmation code expired. The code from your old PDS is only valid for a limited time. Please request a new one.'

  # UpdatePlcJob — rescue block, pre-submission
  PLC_PRE_SUBMISSION_GENERIC       = 'PLC update failed (before submission) - Failed to get recommended PLC operation: 500 Internal Server Error'
  PLC_PRE_SUBMISSION_NETWORK       = 'PLC update failed (before submission) - GoatService::NetworkError: connection timed out'

  # UpdatePlcJob — rescue block, post-submission (CRITICAL)
  PLC_POST_SUBMISSION              = 'CRITICAL: PLC update failed after submission - Failed to activate account: 500 Internal Server Error'

  # UpdatePlcJob — credential validation
  CREDENTIALS_EXPIRED_OLD_SESSION  = 'Credentials expired: old PDS session no longer available. Please re-authenticate to continue.'
  CREDENTIALS_EXPIRED_BOTH         = 'Credentials expired: new PDS session and old PDS session no longer available. Please re-authenticate to continue.'
  CREDENTIALS_EXPIRED_NEW_PASSWORD = 'Credentials expired: new PDS password no longer available. Please re-authenticate to continue.'

  # Legacy error message (from old code before pre/post split)
  LEGACY_CRITICAL_PLC              = 'CRITICAL: PLC update failed - Failed to sign PLC operation: 400 Bad Request: Token is expired'

  # Rate limiting
  RATE_LIMIT_429                   = 'HTTP 429: Too Many Requests'
  RATE_LIMIT_TEXT                  = 'Rate limit exceeded for createRecord'
  RATE_LIMIT_CLASS                 = 'RateLimitExceeded: Too many requests, retry after 30s'

  # Network errors
  NETWORK_TIMEOUT                  = 'GoatService::NetworkError: connection timed out'
  NETWORK_UNREACHABLE              = 'Network unreachable: https://oldpds.example.com'

  # Authentication errors
  AUTH_INVALID_PASSWORD             = 'authentication failed: invalid password'
  AUTH_401                         = 'HTTP 401 Unauthorized'

  # Account exists / orphaned
  ACCOUNT_EXISTS                   = 'Account already exists on target PDS'
  ACCOUNT_ORPHANED                 = 'DID already exists - orphaned account detected'

  # Invite code
  INVITE_CODE_INVALID              = 'Invalid invite code: INVITE-XYZ'

  # Blob not found
  BLOB_NOT_FOUND                   = 'blob not found: bafybeiabc123 returned 404'

  # Data corruption
  DATA_CORRUPT                     = 'corrupt CAR file: invalid format'

  # Disk space
  DISK_FULL                        = 'disk full: out of space on /data'

  # Cancelled
  CANCELLED                        = 'Migration cancelled by user'

  # ============================================================================
  # 1. Each canonical message maps to its expected error type
  # ============================================================================

  # --- PLC token expired / missing ---

  test "detects PLC token expired with timestamp" do
    assert_equal :plc_token_expired, detect(PLC_TOKEN_EXPIRED_WITH_TIMESTAMP)
  end

  test "detects PLC token missing" do
    assert_equal :plc_token_expired, detect(PLC_TOKEN_MISSING)
  end

  test "detects PLC confirmation code expired" do
    assert_equal :plc_token_expired, detect(PLC_CONFIRMATION_CODE_EXPIRED)
  end

  # --- PLC pre-submission failure ---

  test "detects PLC pre-submission generic failure" do
    assert_equal :plc_pre_submission_failure, detect(PLC_PRE_SUBMISSION_GENERIC)
  end

  test "detects PLC pre-submission network failure" do
    assert_equal :plc_pre_submission_failure, detect(PLC_PRE_SUBMISSION_NETWORK)
  end

  # --- PLC post-submission (critical) ---

  test "detects PLC post-submission critical failure" do
    assert_equal :critical_plc, detect(PLC_POST_SUBMISSION)
  end

  test "detects legacy critical PLC failure" do
    assert_equal :critical_plc, detect(LEGACY_CRITICAL_PLC)
  end

  # --- Credentials need re-authentication ---

  test "detects credentials expired (old session)" do
    assert_equal :credentials_need_reauth, detect(CREDENTIALS_EXPIRED_OLD_SESSION)
  end

  test "detects credentials expired (both sessions)" do
    assert_equal :credentials_need_reauth, detect(CREDENTIALS_EXPIRED_BOTH)
  end

  test "detects credentials expired (new password)" do
    assert_equal :credentials_need_reauth, detect(CREDENTIALS_EXPIRED_NEW_PASSWORD)
  end

  # --- Rate limiting ---

  test "detects HTTP 429 rate limit" do
    assert_equal :rate_limit, detect(RATE_LIMIT_429)
  end

  test "detects rate limit text" do
    assert_equal :rate_limit, detect(RATE_LIMIT_TEXT)
  end

  test "detects RateLimitExceeded class" do
    assert_equal :rate_limit, detect(RATE_LIMIT_CLASS)
  end

  # --- Network ---

  test "detects network timeout" do
    assert_equal :network, detect(NETWORK_TIMEOUT)
  end

  test "detects network unreachable" do
    assert_equal :network, detect(NETWORK_UNREACHABLE)
  end

  # --- Authentication ---

  test "detects invalid password" do
    assert_equal :authentication, detect(AUTH_INVALID_PASSWORD)
  end

  test "detects HTTP 401" do
    assert_equal :authentication, detect(AUTH_401)
  end

  # --- Account exists ---

  test "detects account already exists" do
    assert_equal :account_exists, detect(ACCOUNT_EXISTS)
  end

  test "detects orphaned account" do
    assert_equal :account_exists, detect(ACCOUNT_ORPHANED)
  end

  # --- Invite code ---

  test "detects invalid invite code" do
    assert_equal :invite_code, detect(INVITE_CODE_INVALID)
  end

  # --- Blob not found ---

  test "detects blob not found" do
    assert_equal :blob_not_found, detect(BLOB_NOT_FOUND)
  end

  # --- Data corruption ---

  test "detects data corruption" do
    assert_equal :data_corruption, detect(DATA_CORRUPT)
  end

  # --- Disk space ---

  test "detects disk full" do
    assert_equal :disk_space, detect(DISK_FULL)
  end

  # --- Cancelled ---

  test "detects cancelled by user" do
    assert_equal :cancelled, detect(CANCELLED)
  end

  # --- Unknown → generic ---

  test "unknown error falls through to generic" do
    assert_equal :generic, detect("Something completely unexpected happened")
  end

  # ============================================================================
  # 2. Cross-matching prevention — ensure no message matches the wrong type
  # ============================================================================

  # The original bug: "Token is expired" in a PLC error was caught by a broad
  # "expired" regex intended for credentials. These tests guarantee isolation.

  test "credential errors never match plc_token_expired" do
    [CREDENTIALS_EXPIRED_OLD_SESSION, CREDENTIALS_EXPIRED_BOTH, CREDENTIALS_EXPIRED_NEW_PASSWORD].each do |msg|
      refute_equal :plc_token_expired, detect(msg),
        "Credential error should not match :plc_token_expired — message: #{msg}"
    end
  end

  test "PLC token errors never match credentials_need_reauth" do
    [PLC_TOKEN_EXPIRED_WITH_TIMESTAMP, PLC_TOKEN_MISSING, PLC_CONFIRMATION_CODE_EXPIRED].each do |msg|
      refute_equal :credentials_need_reauth, detect(msg),
        "PLC token error should not match :credentials_need_reauth — message: #{msg}"
    end
  end

  test "pre-submission PLC errors never match critical_plc" do
    [PLC_PRE_SUBMISSION_GENERIC, PLC_PRE_SUBMISSION_NETWORK,
     PLC_TOKEN_EXPIRED_WITH_TIMESTAMP, PLC_TOKEN_MISSING, PLC_CONFIRMATION_CODE_EXPIRED].each do |msg|
      refute_equal :critical_plc, detect(msg),
        "Pre-submission error should not match :critical_plc — message: #{msg}"
    end
  end

  test "post-submission PLC errors never match plc_pre_submission_failure" do
    refute_equal :plc_pre_submission_failure, detect(PLC_POST_SUBMISSION)
  end

  test "legacy critical PLC error does not match plc_token_expired" do
    refute_equal :plc_token_expired, detect(LEGACY_CRITICAL_PLC)
  end

  # ============================================================================
  # 3. Anchoring verification — patterns must not match substrings mid-message
  # ============================================================================

  test "PLC token patterns require start-of-string anchor" do
    # If someone wraps a PLC message inside another message, it must NOT match
    wrapped = "Retry failed: PLC token has expired (expired at: ...). Please request a new token."
    refute_equal :plc_token_expired, detect(wrapped),
      "Wrapped PLC message should not match :plc_token_expired (\\A anchor test)"
  end

  test "credential pattern requires start-of-string anchor" do
    wrapped = "Something else: Credentials expired: old PDS session no longer available. Please re-authenticate to continue."
    refute_equal :credentials_need_reauth, detect(wrapped),
      "Wrapped credential message should not match :credentials_need_reauth (\\A anchor test)"
  end

  test "critical PLC pattern requires start-of-string anchor" do
    wrapped = "Info: CRITICAL: PLC update failed after submission - error"
    refute_equal :critical_plc, detect(wrapped),
      "Wrapped CRITICAL message should not match :critical_plc (\\A anchor test)"
  end

  # ============================================================================
  # 4. Stability contract — error types that control UI elements
  # ============================================================================

  test "all PLC recoverable types trigger show_request_new_plc_token" do
    migration = migrations(:pending_migration)
    migration.update!(status: :failed, old_pds_host: 'https://old.example.com', new_pds_host: 'https://new.example.com')

    [:plc_token_expired, :plc_pre_submission_failure].each do |error_type|
      # Pick a canonical message that maps to this type
      msg = case error_type
            when :plc_token_expired then PLC_TOKEN_EXPIRED_WITH_TIMESTAMP
            when :plc_pre_submission_failure then PLC_PRE_SUBMISSION_GENERIC
            end

      migration.update!(last_error: msg)
      context = MigrationErrorHelper.explain_error(migration)

      assert context[:show_request_new_plc_token],
        "Error type #{error_type} must set show_request_new_plc_token"
      assert_equal :warning, context[:severity],
        "Error type #{error_type} must be severity :warning (not :critical or :error)"
    end
  end

  test "credentials_need_reauth triggers show_reauth_form" do
    migration = migrations(:pending_migration)
    migration.update!(
      status: :failed,
      last_error: CREDENTIALS_EXPIRED_OLD_SESSION,
      old_pds_host: 'https://old.example.com',
      new_pds_host: 'https://new.example.com'
    )
    context = MigrationErrorHelper.explain_error(migration)

    assert context[:show_reauth_form],
      ":credentials_need_reauth must set show_reauth_form"
    refute context[:show_request_new_plc_token],
      ":credentials_need_reauth must NOT set show_request_new_plc_token"
  end

  test "critical_plc is severity critical" do
    migration = migrations(:pending_migration)
    migration.update!(
      status: :failed,
      last_error: PLC_POST_SUBMISSION,
      old_pds_host: 'https://old.example.com',
      new_pds_host: 'https://new.example.com',
      progress_data: { 'plc_operation_submitted_at' => Time.current.iso8601 }
    )
    context = MigrationErrorHelper.explain_error(migration)

    assert_equal :critical, context[:severity]
    assert context[:show_contact_support]
  end

  # ============================================================================
  # 5. Full matrix — every type appears at least once
  # ============================================================================

  EXPECTED_TYPES = {
    PLC_TOKEN_EXPIRED_WITH_TIMESTAMP => :plc_token_expired,
    PLC_TOKEN_MISSING                => :plc_token_expired,
    PLC_CONFIRMATION_CODE_EXPIRED    => :plc_token_expired,
    PLC_PRE_SUBMISSION_GENERIC       => :plc_pre_submission_failure,
    PLC_PRE_SUBMISSION_NETWORK       => :plc_pre_submission_failure,
    PLC_POST_SUBMISSION              => :critical_plc,
    LEGACY_CRITICAL_PLC              => :critical_plc,
    CREDENTIALS_EXPIRED_OLD_SESSION  => :credentials_need_reauth,
    CREDENTIALS_EXPIRED_BOTH         => :credentials_need_reauth,
    CREDENTIALS_EXPIRED_NEW_PASSWORD => :credentials_need_reauth,
    RATE_LIMIT_429                   => :rate_limit,
    RATE_LIMIT_TEXT                  => :rate_limit,
    RATE_LIMIT_CLASS                 => :rate_limit,
    NETWORK_TIMEOUT                  => :network,
    NETWORK_UNREACHABLE              => :network,
    AUTH_INVALID_PASSWORD             => :authentication,
    AUTH_401                         => :authentication,
    ACCOUNT_EXISTS                   => :account_exists,
    ACCOUNT_ORPHANED                 => :account_exists,
    INVITE_CODE_INVALID              => :invite_code,
    BLOB_NOT_FOUND                   => :blob_not_found,
    DATA_CORRUPT                     => :data_corruption,
    DISK_FULL                        => :disk_space,
    CANCELLED                        => :cancelled,
  }.freeze

  test "full matrix — every canonical message maps correctly" do
    EXPECTED_TYPES.each do |message, expected_type|
      actual = detect(message)
      assert_equal expected_type, actual,
        "Expected #{expected_type.inspect} for message: #{message.truncate(80)}, got #{actual.inspect}"
    end
  end

  test "full matrix covers all non-generic error types" do
    all_types_covered = EXPECTED_TYPES.values.uniq.sort
    # These are all the specific (non-generic) types the helper should handle
    expected_types = %i[
      plc_token_expired critical_plc plc_pre_submission_failure
      credentials_need_reauth rate_limit network authentication
      account_exists invite_code blob_not_found data_corruption
      disk_space cancelled
    ].sort

    assert_equal expected_types, all_types_covered,
      "Test matrix should cover all non-generic error types"
  end

  # ============================================================================
  # 6. error_code preference — explain_error uses error_code over regex
  # ============================================================================

  test "explain_error prefers error_code over regex when both present" do
    migration = migrations(:pending_migration)
    migration.update!(
      status: :failed,
      last_error: "Something completely unrecognizable by regex",
      error_code: "plc_token_expired",
      old_pds_host: "https://old.example.com",
      new_pds_host: "https://new.example.com"
    )

    context = MigrationErrorHelper.explain_error(migration)

    # Should use error_code (:plc_token_expired) NOT regex (:generic)
    assert_equal "PLC Token Expired", context[:title]
    assert context[:show_request_new_plc_token],
      "Should use error_code to determine context, not regex on last_error"
  end

  test "explain_error prefers error_code even when regex would match differently" do
    migration = migrations(:pending_migration)
    # last_error matches :network via regex, but error_code says :plc_token_expired
    migration.update!(
      status: :failed,
      last_error: "Network unreachable: connection timed out",
      error_code: "plc_token_expired",
      old_pds_host: "https://old.example.com",
      new_pds_host: "https://new.example.com"
    )

    context = MigrationErrorHelper.explain_error(migration)

    assert_equal "PLC Token Expired", context[:title],
      "error_code should take precedence over regex match on last_error"
  end

  test "explain_error falls back to regex when error_code is nil" do
    migration = migrations(:pending_migration)
    migration.update!(
      status: :failed,
      last_error: PLC_TOKEN_EXPIRED_WITH_TIMESTAMP,
      error_code: nil,
      old_pds_host: "https://old.example.com",
      new_pds_host: "https://new.example.com"
    )

    context = MigrationErrorHelper.explain_error(migration)

    assert_equal "PLC Token Expired", context[:title],
      "Should fall back to regex detection when error_code is nil"
    assert context[:show_request_new_plc_token]
  end

  test "explain_error falls back to regex when error_code is empty string" do
    migration = migrations(:pending_migration)
    migration.update!(
      status: :failed,
      last_error: CREDENTIALS_EXPIRED_OLD_SESSION,
      error_code: "",
      old_pds_host: "https://old.example.com",
      new_pds_host: "https://new.example.com"
    )

    context = MigrationErrorHelper.explain_error(migration)

    assert_equal "Session Expired — Re-authentication Required", context[:title],
      "Should fall back to regex when error_code is empty string"
    assert context[:show_reauth_form]
  end

  test "explain_error handles all error_code values" do
    migration = migrations(:pending_migration)
    migration.update!(
      status: :failed,
      last_error: "irrelevant",
      old_pds_host: "https://old.example.com",
      new_pds_host: "https://new.example.com",
      progress_data: {}
    )

    # Map of error_code -> expected title (validates build_error_context routing)
    expected_titles = {
      "plc_token_expired"          => "PLC Token Expired",
      "plc_pre_submission_failure" => "PLC Update Could Not Complete",
      "critical_plc"               => "PLC Directory Update Failed",
      "credentials_need_reauth"    => "Session Expired — Re-authentication Required",
      "authentication"             => "Authentication Failed",
      "network"                    => "Network Connection Error",
      "rate_limit"                 => "Rate Limited by Server",
      "account_exists"             => "Account Already Exists on Target PDS",
      "invite_code"                => "Invalid or Expired Invite Code",
      "blob_not_found"             => "Some Blobs Not Found",
      "data_corruption"            => "Data Transfer Corruption",
      "disk_space"                 => "Disk Space Exhausted",
      "cancelled"                  => "Migration Cancelled",
      "generic"                    => "Migration Error",
    }

    expected_titles.each do |code, expected_title|
      migration.update!(error_code: code)
      context = MigrationErrorHelper.explain_error(migration)
      assert_equal expected_title, context[:title],
        "error_code '#{code}' should produce title '#{expected_title}', got '#{context[:title]}'"
    end
  end

  private

  def detect(message)
    MigrationErrorHelper.detect_error_type(message)
  end
end
