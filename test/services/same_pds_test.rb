require "test_helper"

# Moving an account onto the PDS it already lives on would end with
# ActivateAccountJob deactivating it, so the wizard and create must recognise
# the same server, also under a second name.
class SamePdsTest < ActiveSupport::TestCase
  test "the same host in any spelling is the same server, without asking it" do
    HTTParty.expects(:get).never

    assert GoatService.same_pds?("https://eurosky.social", "https://eurosky.social")
    assert GoatService.same_pds?("https://eurosky.social/", "EUROSKY.social")
    assert GoatService.same_pds_host?("eurosky.social", "https://eurosky.social:443")
  end

  test "two names for one server are the same server" do
    # myatproto.social and blacksky.app both describe themselves as did:web:blacksky.app
    stub_describe_server("https://myatproto.social", did: "did:web:blacksky.app")
    stub_describe_server("https://blacksky.app", did: "did:web:blacksky.app")

    assert GoatService.same_pds?("https://blacksky.app", "https://myatproto.social")
    refute GoatService.same_pds_host?("https://blacksky.app", "https://myatproto.social")
  end

  test "different servers are not the same" do
    stub_describe_server("https://eurosky.social", did: "did:web:eurosky.social")
    stub_describe_server("https://blacksky.app", did: "did:web:blacksky.app")

    refute GoatService.same_pds?("https://eurosky.social", "https://blacksky.app")
  end

  test "a server that can't be asked is only the same if the host is" do
    HTTParty.stubs(:get).raises(Net::OpenTimeout)

    refute GoatService.same_pds?("https://eurosky.social", "https://blacksky.app")
    refute GoatService.same_pds_host?("https://pds.example.com:8443", "https://pds.example.com")
    refute GoatService.same_pds_host?(nil, nil)
  end

  test "a handle on a built-in suffix is PDS-owned without asking anyone" do
    GoatService.expects(:handle_matches_source_pds?).never

    assert GoatService.pds_owned_handle?("@Alice.bsky.social")
  end

  test "pds_owned_handle? passes when_unknown through" do
    GoatService.expects(:handle_matches_source_pds?).with("iustitia100.latinsky.app", when_unknown: false).returns(false)

    refute GoatService.pds_owned_handle?("iustitia100.latinsky.app", when_unknown: false)
  end

  private

  def stub_describe_server(host, did:)
    response = stub(success?: true, code: 200, body: { did: did, availableUserDomains: [] }.to_json)
    HTTParty.stubs(:get).with("#{host}/xrpc/com.atproto.server.describeServer", timeout: 5).returns(response)
  end
end
