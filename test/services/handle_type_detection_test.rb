require "test_helper"

class HandleTypeDetectionTest < ActiveSupport::TestCase
  test "a handle on a built-in PDS-hosted suffix is PDS-hosted without any lookup" do
    GoatService.expects(:handle_matches_source_pds?).never

    result = GoatService.detect_handle_type("alice.bsky.social")

    assert_equal "pds_hosted", result[:type]
    assert_equal false, result[:can_preserve]
  end

  test "a configured suffix makes handles on it PDS-hosted" do
    # pds.oso.social answers well-known for *.oso.social, so without the suffix
    # these handles would be offered as keepable custom domains.
    EuroskyConfig.stubs(:pds_hosted_handle_suffixes).returns(%w[.bsky.social .oso.social])
    GoatService.expects(:handle_matches_source_pds?).never

    result = GoatService.detect_handle_type("Spotchi.oso.social")

    assert_equal "pds_hosted", result[:type]
    assert_equal false, result[:can_preserve]
  end
end
