require "test_helper"

class LegalSnapshotTest < ActiveSupport::TestCase
  def setup
    @valid_attributes = {
      document_type: "privacy_policy",
      content_hash: Digest::SHA256.hexdigest("test content"),
      rendered_content: "<html>test content</html>",
      version_label: "2026-03-04"
    }
  end

  # ============================================================================
  # Validations
  # ============================================================================

  test "valid attributes" do
    snapshot = LegalSnapshot.new(@valid_attributes)
    assert snapshot.valid?
  end

  test "requires document_type" do
    snapshot = LegalSnapshot.new(@valid_attributes.except(:document_type))
    assert_not snapshot.valid?
    assert_includes snapshot.errors[:document_type], "can't be blank"
  end

  test "validates document_type inclusion" do
    snapshot = LegalSnapshot.new(@valid_attributes.merge(document_type: "invalid_type"))
    assert_not snapshot.valid?
    assert snapshot.errors[:document_type].any? { |msg| msg.include?("is not included") }
  end

  test "allows privacy_policy document_type" do
    snapshot = LegalSnapshot.new(@valid_attributes.merge(document_type: "privacy_policy"))
    assert snapshot.valid?
  end

  test "allows terms_of_service document_type" do
    snapshot = LegalSnapshot.new(@valid_attributes.merge(document_type: "terms_of_service"))
    assert snapshot.valid?
  end

  test "requires content_hash" do
    snapshot = LegalSnapshot.new(@valid_attributes.except(:content_hash))
    assert_not snapshot.valid?
    assert_includes snapshot.errors[:content_hash], "can't be blank"
  end

  test "requires rendered_content" do
    snapshot = LegalSnapshot.new(@valid_attributes.except(:rendered_content))
    assert_not snapshot.valid?
    assert_includes snapshot.errors[:rendered_content], "can't be blank"
  end

  test "requires version_label" do
    snapshot = LegalSnapshot.new(@valid_attributes.except(:version_label))
    assert_not snapshot.valid?
    assert_includes snapshot.errors[:version_label], "can't be blank"
  end

  # ============================================================================
  # snapshot_if_changed!
  # ============================================================================

  test "snapshot_if_changed! creates new snapshot for new content" do
    assert_difference "LegalSnapshot.count", 1 do
      snapshot = LegalSnapshot.snapshot_if_changed!("privacy_policy", "<html>new content</html>")
      assert_equal "privacy_policy", snapshot.document_type
      assert_equal Digest::SHA256.hexdigest("<html>new content</html>"), snapshot.content_hash
      assert_equal "<html>new content</html>", snapshot.rendered_content
      assert_equal Date.current.iso8601, snapshot.version_label
    end
  end

  test "snapshot_if_changed! returns existing snapshot for unchanged content" do
    html = "<html>same content</html>"
    first = LegalSnapshot.snapshot_if_changed!("privacy_policy", html)

    assert_no_difference "LegalSnapshot.count" do
      second = LegalSnapshot.snapshot_if_changed!("privacy_policy", html)
      assert_equal first.id, second.id
    end
  end

  test "snapshot_if_changed! creates separate snapshots for different document types" do
    html = "<html>shared content</html>"

    assert_difference "LegalSnapshot.count", 2 do
      pp_snapshot = LegalSnapshot.snapshot_if_changed!("privacy_policy", html)
      tos_snapshot = LegalSnapshot.snapshot_if_changed!("terms_of_service", html)
      assert_not_equal pp_snapshot.id, tos_snapshot.id
    end
  end

  test "snapshot_if_changed! creates new snapshot when content changes" do
    LegalSnapshot.snapshot_if_changed!("privacy_policy", "<html>version 1</html>")

    assert_difference "LegalSnapshot.count", 1 do
      snapshot = LegalSnapshot.snapshot_if_changed!("privacy_policy", "<html>version 2</html>")
      assert_equal Digest::SHA256.hexdigest("<html>version 2</html>"), snapshot.content_hash
    end
  end

  test "snapshot_if_changed! marks new records as previously_new_record" do
    snapshot = LegalSnapshot.snapshot_if_changed!("privacy_policy", "<html>brand new</html>")
    assert snapshot.previously_new_record?
  end

  test "snapshot_if_changed! existing records are not previously_new_record" do
    html = "<html>existing</html>"
    LegalSnapshot.snapshot_if_changed!("privacy_policy", html)

    snapshot = LegalSnapshot.snapshot_if_changed!("privacy_policy", html)
    assert_not snapshot.previously_new_record?
  end

  # ============================================================================
  # current
  # ============================================================================

  test "current returns most recent snapshot for document type" do
    old = LegalSnapshot.create!(@valid_attributes.merge(
      content_hash: Digest::SHA256.hexdigest("old"),
      rendered_content: "old",
      version_label: "2026-01-01"
    ))

    new_snapshot = LegalSnapshot.create!(@valid_attributes.merge(
      content_hash: Digest::SHA256.hexdigest("new"),
      rendered_content: "new",
      version_label: "2026-03-04"
    ))

    assert_equal new_snapshot, LegalSnapshot.current("privacy_policy")
  end

  test "current returns nil when no snapshots exist" do
    assert_nil LegalSnapshot.current("privacy_policy")
  end

  test "current only returns snapshots for specified document type" do
    tos = LegalSnapshot.create!(
      document_type: "terms_of_service",
      content_hash: Digest::SHA256.hexdigest("tos"),
      rendered_content: "tos",
      version_label: "2026-03-04"
    )

    assert_nil LegalSnapshot.current("privacy_policy")
    assert_equal tos, LegalSnapshot.current("terms_of_service")
  end

  # ============================================================================
  # Scopes
  # ============================================================================

  test "for_type scope filters by document_type" do
    pp = LegalSnapshot.create!(@valid_attributes)
    tos = LegalSnapshot.create!(@valid_attributes.merge(
      document_type: "terms_of_service",
      content_hash: Digest::SHA256.hexdigest("tos content")
    ))

    assert_includes LegalSnapshot.for_type("privacy_policy"), pp
    assert_not_includes LegalSnapshot.for_type("privacy_policy"), tos
  end
end
