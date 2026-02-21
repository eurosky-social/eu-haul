require "test_helper"

# GoatService Handle Sanitization Tests
# Tests for GoatService.clean_handle which sanitizes user-provided handles
# by stripping whitespace, removing @ prefix, removing Unicode bidi control
# characters, and downcasing.
class HandleSanitizationTest < ActiveSupport::TestCase
  # ============================================================================
  # GoatService.clean_handle
  # ============================================================================

  test "strips leading and trailing whitespace" do
    assert_equal "user.bsky.social", GoatService.clean_handle("  user.bsky.social  ")
  end

  test "removes @ prefix" do
    assert_equal "user.bsky.social", GoatService.clean_handle("@user.bsky.social")
  end

  test "removes Unicode bidi control characters" do
    bidi_chars = [
      "\u200E",  # LEFT-TO-RIGHT MARK
      "\u200F",  # RIGHT-TO-LEFT MARK
      "\u202A",  # LEFT-TO-RIGHT EMBEDDING
      "\u202E",  # RIGHT-TO-LEFT OVERRIDE
      "\u2066",  # LEFT-TO-RIGHT ISOLATE
      "\u2069"   # POP DIRECTIONAL ISOLATE
    ]

    bidi_chars.each do |char|
      handle_with_bidi = "user#{char}.bsky.social"
      result = GoatService.clean_handle(handle_with_bidi)
      assert_equal "user.bsky.social", result,
        "Should remove bidi character U+#{char.ord.to_s(16).upcase} from handle"
    end
  end

  test "downcases handle" do
    assert_equal "user.bsky.social", GoatService.clean_handle("User.Bsky.Social")
  end

  test "handles combined dirtiness" do
    assert_equal "user.bsky.social", GoatService.clean_handle("  @User\u200E.Bsky.Social  ")
  end

  test "returns nil for nil input" do
    assert_nil GoatService.clean_handle(nil)
  end

  test "returns empty string for empty input" do
    assert_equal "", GoatService.clean_handle("")
  end
end
