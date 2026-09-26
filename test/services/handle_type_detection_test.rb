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

  test "a handle on a domain its source PDS hands out is PDS-hosted without any setting" do
    # eurosky.social hands out .mu.social as well as its hostname; the PDS
    # answers well-known for both, so only its own list tells them apart.
    source_pds_is("https://eurosky.social", domains: %w[.eurosky.social .mu.social])

    result = GoatService.detect_handle_type("seconds11.mu.social")

    assert_equal "pds_hosted", result[:type]
    assert_equal false, result[:can_preserve]
    assert_equal "pds_api", result[:verified_via] # not the error fallback, which is also pds_hosted
  end

  test "a custom domain on a PDS that doesn't hand it out is not PDS-owned" do
    source_pds_is("https://eurosky.social", domains: %w[.eurosky.social .mu.social])

    assert_equal false, GoatService.handle_matches_source_pds?("alice.example.com")
  end

  test "the PDS hostname still counts without asking the PDS" do
    source_pds_is("https://pds.example.com")
    HTTParty.expects(:get).never

    assert_equal true, GoatService.handle_matches_source_pds?("alice.pds.example.com")
  end

  test "PDS handle domains are normalized and junk entries dropped" do
    stub_describe_server("https://pds.example.com",
                         body: { availableUserDomains: ["MU.social", ".social", 42, ".eurosky.social"] })

    assert_equal %w[.mu.social .eurosky.social], GoatService.pds_handle_domains("https://pds.example.com/")
  end

  test "an unreachable or failing describeServer means no domains, not an error" do
    HTTParty.stubs(:get).raises(Net::OpenTimeout)
    assert_equal [], GoatService.pds_handle_domains("https://pds.example.com")

    stub_describe_server("https://pds.example.com", body: { error: "InternalServerError" }, success: false)
    assert_equal [], GoatService.pds_handle_domains("https://pds.example.com")

    stub_describe_server("https://pds.example.com", body: { did: "did:web:pds.example.com" })
    assert_equal [], GoatService.pds_handle_domains("https://pds.example.com")
  end

  private

  def source_pds_is(pds_host, domains: nil)
    GoatService.stubs(:resolve_handle_to_did).returns("did:plc:abc123")
    GoatService.stubs(:resolve_did_to_pds).with("did:plc:abc123").returns(pds_host)
    stub_describe_server(pds_host, body: { availableUserDomains: domains }) if domains
  end

  def stub_describe_server(pds_host, body:, success: true)
    response = stub(success?: success, code: success ? 200 : 500, body: body.to_json)
    HTTParty.stubs(:get).with("#{pds_host}/xrpc/com.atproto.server.describeServer", timeout: 5).returns(response)
  end
end
