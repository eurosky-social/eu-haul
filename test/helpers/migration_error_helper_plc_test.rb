require "test_helper"

# MigrationErrorHelper PLC Token Expiration Tests
# Tests for PLC token expired error context generation
class MigrationErrorHelperPlcTest < ActiveSupport::TestCase
  def setup
    @migration = migrations(:pending_migration)
    @migration.update!(
      status: :failed,
      old_pds_host: 'https://oldpds.example.com',
      new_pds_host: 'https://newpds.example.com',
      credentials_expires_at: 1.hour.ago,
      last_error: "PLC token has expired (expired at: #{1.hour.ago}). Please request a new token."
    )
  end

  # ============================================================================
  # Error Type Detection
  # ============================================================================

  test "detect_error_type identifies PLC token expired error" do
    error_message = "PLC token has expired (expired at: 2026-02-11 20:00:00 UTC). Please request a new token."
    error_type = MigrationErrorHelper.detect_error_type(error_message)
    assert_equal :plc_token_expired, error_type
  end

  test "detect_error_type distinguishes PLC token expiration from credential expiration" do
    plc_error = "PLC token has expired (expired at: 2026-02-11 20:00:00 UTC). Please request a new token."
    cred_error = "Credentials expired: old PDS session no longer available. Please re-authenticate to continue."

    assert_equal :plc_token_expired, MigrationErrorHelper.detect_error_type(plc_error)
    assert_equal :credentials_need_reauth, MigrationErrorHelper.detect_error_type(cred_error)
  end

  # ============================================================================
  # Error Context Generation
  # ============================================================================

  test "plc_token_expired_context generates appropriate error context" do
    context = MigrationErrorHelper.explain_error(@migration)

    assert_not_nil context
    assert_equal :warning, context[:severity]
    assert_equal "⏰", context[:icon]
    assert_equal "PLC token expired", context[:title]
    assert_match(/PLC operation token.*expired/i, context[:what_happened])
    assert_match(/only valid for 15 minutes/i, context[:what_happened])
    assert_equal "Migration paused — you need a new PLC token", context[:current_status]
  end

  test "plc_token_expired_context includes actionable steps" do
    context = MigrationErrorHelper.explain_error(@migration)

    assert context[:what_to_do].is_a?(Array)
    # Names the button exactly as the page labels it
    assert context[:what_to_do].any? { |step| step.include?(I18n.t("migrations.error_details.request_plc_action")) }
    # The sender is named the way the inbox shows it: bare host, no scheme
    assert context[:what_to_do].any? { |step| step.include?("oldpds.example.com") }
    refute context[:what_to_do].any? { |step| step.include?("https://oldpds") }
    assert context[:what_to_do].any? { |step| step.include?("within 15 minutes") }
    assert context[:what_to_do].any? { |step| step.include?("migration data is safe") }
  end

  test "plc_token_expired_context sets show_request_new_plc_token flag" do
    context = MigrationErrorHelper.explain_error(@migration)

    assert context[:show_request_new_plc_token]
    assert_not context[:show_retry_button]
    assert_not context[:show_new_migration_button]
  end

  test "plc_token_expired_context includes technical details" do
    context = MigrationErrorHelper.explain_error(@migration)

    assert_equal @migration.last_error, context[:technical_details]
    assert_equal @migration.credentials_expires_at, context[:expired_at]
    assert_equal @migration.old_pds_host, context[:old_pds_host]
  end

  test "plc_token_expired_context includes help link" do
    context = MigrationErrorHelper.explain_error(@migration)

    assert_equal "/docs/troubleshooting#plc-token-expiration", context[:help_link]
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  test "explain_error returns nil when no error present" do
    @migration.update!(last_error: nil)
    context = MigrationErrorHelper.explain_error(@migration)

    assert_nil context
  end

  test "plc_token_expired_context handles missing old_pds_host gracefully" do
    # Stub old_pds_host to return nil (DB has NOT NULL constraint, so we can't persist nil)
    @migration.stubs(:old_pds_host).returns(nil)
    context = MigrationErrorHelper.explain_error(@migration)

    assert_not_nil context
    # Should not raise error, even with nil old_pds_host
    assert context[:what_to_do].any? { |step| step.is_a?(String) }
  end

# ============================================================================
# Code the old PDS did not recognise ("Token is invalid")
# ============================================================================

NOT_RECOGNISED = "PLC confirmation code not recognised by your old PDS. Request a new code and enter it exactly as it appears in the newest email."

test "detect_error_type identifies a PLC code the old PDS did not recognise" do
  assert_equal :plc_token_invalid, MigrationErrorHelper.detect_error_type(NOT_RECOGNISED)
end

test "plc_token_invalid_context tells the user to use only the newest code, copied exactly" do
  @migration.update!(error_code: "plc_token_invalid", last_error: NOT_RECOGNISED)

  context = MigrationErrorHelper.explain_error(@migration)

  assert_equal :warning, context[:severity]
  assert_equal I18n.t("migrations.error_messages.plc_token_invalid.title"), context[:title]
  assert_includes context[:what_happened], @migration.old_pds_host
  assert context[:show_request_new_plc_token]
  refute context[:show_retry_button]
  assert context[:what_to_do].any? { |step| step.include?("most recent email") }
  assert context[:what_to_do].any? { |step| step.include?("XXXXX-XXXXX") }
  assert context[:what_to_do].any? { |step| step.include?(I18n.t("migrations.error_details.request_plc_action")) }
end

test "the advice names Bluesky as the sender for a Bluesky-hosted account" do
  @migration.update!(old_pds_host: "https://shimeji.us-east.host.bsky.network")

  context = MigrationErrorHelper.explain_error(@migration)

  assert context[:what_to_do].any? { |step| step.include?("Bluesky (noreply@bsky.app)") }
  refute context[:what_to_do].any? { |step| step.include?("shimeji") }
end
end
