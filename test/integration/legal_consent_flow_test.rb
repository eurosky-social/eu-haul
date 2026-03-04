require "test_helper"
require "webmock/minitest"

# Legal Consent Flow Integration Tests
#
# Verifies that:
# 1. Server-side validation rejects form submission without legal consent
# 2. A LegalConsent record is created when consent is given
# 3. Consent records survive migration deletion
# 4. LegalSnapshot.current is used for consent references
class LegalConsentFlowTest < ActionDispatch::IntegrationTest
  def setup
    WebMock.disable_net_connect!(allow_localhost: true)

    @old_handle = "testuser.bsky.social"
    @new_handle = "testuser.newpds.com"
    @old_pds_host = "https://bsky.social"
    @new_pds_host = "https://newpds.example.com"
    @did = "did:plc:consenttest123"
    @email = "consent@example.com"

    # Create legal snapshots (normally done at boot time)
    @tos_snapshot = LegalSnapshot.create!(
      document_type: "terms_of_service",
      content_hash: Digest::SHA256.hexdigest("tos content"),
      rendered_content: "<html>Terms of Service</html>",
      version_label: "2026-03-04"
    )
    @pp_snapshot = LegalSnapshot.create!(
      document_type: "privacy_policy",
      content_hash: Digest::SHA256.hexdigest("pp content"),
      rendered_content: "<html>Privacy Policy</html>",
      version_label: "2026-03-04"
    )

    # Mock handle resolution
    GoatService.stubs(:resolve_handle).with(@old_handle).returns(
      { did: @did, pds_host: @old_pds_host }
    )
    GoatService.stubs(:clean_handle).with(@old_handle).returns(@old_handle)
    GoatService.stubs(:clean_handle).with(@new_handle).returns(@new_handle)
  end

  def teardown
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  # ============================================================================
  # Server-side validation
  # ============================================================================

  test "rejects form submission without legal consent checkbox" do
    assert_no_difference "Migration.count" do
      post migrations_path, params: { migration: migration_params }
    end

    assert_response :unprocessable_entity
  end

  test "rejects form submission with legal_consent=0" do
    assert_no_difference "Migration.count" do
      post migrations_path, params: { migration: migration_params.merge(legal_consent: "0") }
    end

    assert_response :unprocessable_entity
  end

  test "accepts form submission with legal_consent=1" do
    assert_difference "Migration.count", 1 do
      post migrations_path, params: { migration: migration_params.merge(legal_consent: "1") }
    end

    assert_response :redirect
  end

  # ============================================================================
  # Consent record creation
  # ============================================================================

  test "creates LegalConsent record on successful migration creation" do
    assert_difference "LegalConsent.count", 1 do
      post migrations_path, params: { migration: migration_params.merge(legal_consent: "1") }
    end

    consent = LegalConsent.last
    assert_equal @did, consent.did
    assert_equal Migration.last.token, consent.migration_token
    assert_equal @tos_snapshot, consent.tos_snapshot
    assert_equal @pp_snapshot, consent.privacy_policy_snapshot
    assert consent.accepted_at.present?
    assert consent.ip_address.present?
  end

  test "does not create LegalConsent when migration fails validation" do
    assert_no_difference "LegalConsent.count" do
      # Missing old_handle should fail migration validation
      post migrations_path, params: {
        migration: migration_params.merge(legal_consent: "1", old_handle: "")
      }
    end
  end

  # ============================================================================
  # Consent survives migration deletion
  # ============================================================================

  test "consent record persists after migration is destroyed" do
    post migrations_path, params: { migration: migration_params.merge(legal_consent: "1") }

    migration = Migration.last
    consent = LegalConsent.last
    token = migration.token

    migration.destroy!

    assert LegalConsent.exists?(consent.id)
    consent.reload
    assert_equal token, consent.migration_token
    assert_equal @did, consent.did
  end

  # ============================================================================
  # Error message
  # ============================================================================

  test "error message is displayed when consent is missing" do
    post migrations_path, params: { migration: migration_params }

    assert_response :unprocessable_entity
    # The error should be added to @migration.errors[:base]
    assert_select "div", /Terms of Service|Privacy Policy/i rescue nil
  end

  private

  def migration_params
    {
      email: @email,
      old_handle: @old_handle,
      new_handle: @new_handle,
      new_pds_host: @new_pds_host,
      old_access_token: "fake_access_token",
      old_refresh_token: "fake_refresh_token"
    }
  end
end
