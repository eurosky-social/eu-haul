require "test_helper"

# Tests for the boot-time legal snapshotting logic
#
# These test the core snapshot_if_changed! behavior that the initializer
# relies on, rather than testing the initializer boot hook itself (which
# would require reloading the entire Rails app).
class LegalSnapshotsInitializerTest < ActiveSupport::TestCase
  # ============================================================================
  # Simulates what the initializer does at boot time
  # ============================================================================

  test "snapshotting both document types creates two records" do
    assert_difference "LegalSnapshot.count", 2 do
      LegalSnapshot.snapshot_if_changed!("privacy_policy", "<html>Privacy Policy v1</html>")
      LegalSnapshot.snapshot_if_changed!("terms_of_service", "<html>Terms of Service v1</html>")
    end

    assert LegalSnapshot.current("privacy_policy").present?
    assert LegalSnapshot.current("terms_of_service").present?
  end

  test "repeated boot with same content does not create duplicates" do
    # First boot
    LegalSnapshot.snapshot_if_changed!("privacy_policy", "<html>PP</html>")
    LegalSnapshot.snapshot_if_changed!("terms_of_service", "<html>TOS</html>")

    # Second boot (same content)
    assert_no_difference "LegalSnapshot.count" do
      LegalSnapshot.snapshot_if_changed!("privacy_policy", "<html>PP</html>")
      LegalSnapshot.snapshot_if_changed!("terms_of_service", "<html>TOS</html>")
    end
  end

  test "boot after content change creates new snapshot only for changed document" do
    LegalSnapshot.snapshot_if_changed!("privacy_policy", "<html>PP v1</html>")
    LegalSnapshot.snapshot_if_changed!("terms_of_service", "<html>TOS v1</html>")

    # Only privacy policy changed
    assert_difference "LegalSnapshot.count", 1 do
      LegalSnapshot.snapshot_if_changed!("privacy_policy", "<html>PP v2</html>")
      LegalSnapshot.snapshot_if_changed!("terms_of_service", "<html>TOS v1</html>")
    end

    # Current should point to v2
    current_pp = LegalSnapshot.current("privacy_policy")
    assert_equal Digest::SHA256.hexdigest("<html>PP v2</html>"), current_pp.content_hash
  end

  test "version_label uses current date" do
    freeze_time do
      snapshot = LegalSnapshot.snapshot_if_changed!("privacy_policy", "<html>dated</html>")
      assert_equal Date.current.iso8601, snapshot.version_label
    end
  end

  test "new snapshot is detectable via previously_new_record?" do
    snapshot = LegalSnapshot.snapshot_if_changed!("privacy_policy", "<html>new</html>")
    assert snapshot.previously_new_record?, "New snapshot should be flagged as previously_new_record"

    same = LegalSnapshot.snapshot_if_changed!("privacy_policy", "<html>new</html>")
    assert_not same.previously_new_record?, "Existing snapshot should not be flagged as previously_new_record"
  end

  # ============================================================================
  # Content hash correctness
  # ============================================================================

  test "content hash is SHA256 of the rendered HTML" do
    html = "<html><body>Test Content</body></html>"
    expected_hash = Digest::SHA256.hexdigest(html)

    snapshot = LegalSnapshot.snapshot_if_changed!("privacy_policy", html)
    assert_equal expected_hash, snapshot.content_hash
  end

  test "whitespace changes produce different hashes" do
    html1 = "<html>content</html>"
    html2 = "<html> content</html>"

    s1 = LegalSnapshot.snapshot_if_changed!("privacy_policy", html1)
    s2 = LegalSnapshot.snapshot_if_changed!("privacy_policy", html2)

    assert_not_equal s1.content_hash, s2.content_hash
    assert_not_equal s1.id, s2.id
  end

  # ============================================================================
  # Race condition handling
  # ============================================================================

  test "concurrent creation with same hash doesn't raise" do
    html = "<html>concurrent test</html>"
    hash = Digest::SHA256.hexdigest(html)

    # Simulate: another process created the same snapshot between our check and insert
    # by pre-creating it
    LegalSnapshot.create!(
      document_type: "privacy_policy",
      content_hash: hash,
      rendered_content: html,
      version_label: Date.current.iso8601
    )

    # This should not raise, should return the existing record
    assert_no_difference "LegalSnapshot.count" do
      snapshot = LegalSnapshot.snapshot_if_changed!("privacy_policy", html)
      assert_equal hash, snapshot.content_hash
    end
  end
end
