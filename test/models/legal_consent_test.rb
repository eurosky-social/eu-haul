require "test_helper"

class LegalConsentTest < ActiveSupport::TestCase
  def setup
    @tos_snapshot = LegalSnapshot.create!(
      document_type: "terms_of_service",
      content_hash: Digest::SHA256.hexdigest("tos content"),
      rendered_content: "<html>tos</html>",
      version_label: "2026-03-04"
    )
    @pp_snapshot = LegalSnapshot.create!(
      document_type: "privacy_policy",
      content_hash: Digest::SHA256.hexdigest("pp content"),
      rendered_content: "<html>privacy policy</html>",
      version_label: "2026-03-04"
    )
    @valid_attributes = {
      did: "did:plc:abc123xyz",
      migration_token: "EURO-TESTTOK123456789",
      tos_snapshot: @tos_snapshot,
      privacy_policy_snapshot: @pp_snapshot,
      accepted_at: Time.current
    }
  end

  # ============================================================================
  # Validations
  # ============================================================================

  test "valid attributes" do
    consent = LegalConsent.new(@valid_attributes)
    assert consent.valid?
  end

  test "requires did" do
    consent = LegalConsent.new(@valid_attributes.except(:did))
    assert_not consent.valid?
    assert_includes consent.errors[:did], "can't be blank"
  end

  test "requires accepted_at" do
    consent = LegalConsent.new(@valid_attributes.except(:accepted_at))
    assert_not consent.valid?
    assert_includes consent.errors[:accepted_at], "can't be blank"
  end

  test "requires tos_snapshot" do
    consent = LegalConsent.new(@valid_attributes.except(:tos_snapshot))
    assert_not consent.valid?
    assert_includes consent.errors[:tos_snapshot], "must exist"
  end

  test "requires privacy_policy_snapshot" do
    consent = LegalConsent.new(@valid_attributes.except(:privacy_policy_snapshot))
    assert_not consent.valid?
    assert_includes consent.errors[:privacy_policy_snapshot], "must exist"
  end

  test "migration_token is optional" do
    consent = LegalConsent.new(@valid_attributes.except(:migration_token))
    assert consent.valid?
  end

  # ============================================================================
  # Associations
  # ============================================================================

  test "belongs_to tos_snapshot" do
    consent = LegalConsent.create!(@valid_attributes)
    assert_equal @tos_snapshot, consent.tos_snapshot
  end

  test "belongs_to privacy_policy_snapshot" do
    consent = LegalConsent.create!(@valid_attributes)
    assert_equal @pp_snapshot, consent.privacy_policy_snapshot
  end

  # ============================================================================
  # Encryption
  # ============================================================================

  test "encrypts ip_address" do
    consent = LegalConsent.create!(@valid_attributes.merge(ip_address: "192.168.1.100"))
    consent.reload

    assert_equal "192.168.1.100", consent.ip_address
    assert consent.ip_address_ciphertext.present?
    assert_not_equal "192.168.1.100", consent.ip_address_ciphertext
  end

  test "ip_address is optional" do
    consent = LegalConsent.new(@valid_attributes)
    assert_nil consent.ip_address
    assert consent.valid?
  end

  # ============================================================================
  # Scopes
  # ============================================================================

  test "for_did scope filters by DID" do
    consent1 = LegalConsent.create!(@valid_attributes)
    consent2 = LegalConsent.create!(@valid_attributes.merge(
      did: "did:plc:other456",
      migration_token: "EURO-OTHERTOK12345678"
    ))

    results = LegalConsent.for_did("did:plc:abc123xyz")
    assert_includes results, consent1
    assert_not_includes results, consent2
  end

  # ============================================================================
  # Persistence / Independence from Migration
  # ============================================================================

  test "consent record survives migration deletion" do
    migration = Migration.create!(
      did: "did:plc:abc123xyz",
      old_handle: "user.oldpds.com",
      new_handle: "user.newpds.com",
      old_pds_host: "https://oldpds.com",
      new_pds_host: "https://newpds.com",
      email: "user@example.com",
      migration_type: "migration_out",
      password: "test"
    )

    consent = LegalConsent.create!(@valid_attributes.merge(
      migration_token: migration.token
    ))

    migration.destroy!

    assert LegalConsent.exists?(consent.id), "Consent record should survive migration deletion"
    consent.reload
    assert_equal migration.token, consent.migration_token
  end

  test "multiple consents can exist for the same DID" do
    consent1 = LegalConsent.create!(@valid_attributes.merge(
      migration_token: "EURO-FIRST12345678901"
    ))
    consent2 = LegalConsent.create!(@valid_attributes.merge(
      migration_token: "EURO-SECOND1234567890"
    ))

    assert_equal 2, LegalConsent.for_did("did:plc:abc123xyz").count
  end
end
