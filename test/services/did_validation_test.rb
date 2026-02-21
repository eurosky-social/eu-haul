require "test_helper"
require "webmock/minitest"

# GoatService DID Validation Tests
#
# Tests for DID validation after account creation on the new PDS.
# When create_account_on_new_pds succeeds, the response should contain
# the same DID that was requested. A mismatch indicates a critical error
# where the wrong account may have been created.
#
# The validation logic (lines 277-282 of goat_service.rb):
#   - If the response contains a DID and it doesn't match migration.did,
#     raise GoatError with "DID mismatch" message
#   - If the response has no DID field, skip validation (graceful handling)
#   - If the DID matches, proceed normally
class GoatServiceDidValidationTest < ActiveSupport::TestCase
  def setup
    WebMock.disable_net_connect!(allow_localhost: false)
    @migration = migrations(:pending_migration)
    @migration.set_password("test_password_123")
    @migration.old_access_token = mock_jwt
    @migration.old_refresh_token = mock_jwt(exp: 90.days.from_now.to_i)
    @migration.save!
    @service = GoatService.new(@migration)
  end

  def teardown
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  # ============================================================================
  # DID Validation on Account Creation
  # ============================================================================

  test "create_account_on_new_pds succeeds when DID matches" do
    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.server.createAccount")
      .to_return(
        status: 200,
        body: {
          did: @migration.did,
          handle: @migration.new_handle,
          accessJwt: mock_jwt,
          refreshJwt: mock_jwt
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    assert_nothing_raised do
      @service.create_account_on_new_pds('test-service-auth-token')
    end
  end

  test "create_account_on_new_pds raises GoatError on DID mismatch" do
    wrong_did = "did:plc:completely_wrong_did"

    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.server.createAccount")
      .to_return(
        status: 200,
        body: {
          did: wrong_did,
          handle: @migration.new_handle,
          accessJwt: mock_jwt,
          refreshJwt: mock_jwt
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    error = assert_raises(GoatService::GoatError) do
      @service.create_account_on_new_pds('test-service-auth-token')
    end

    assert_match /DID mismatch/, error.message
    assert_match @migration.did, error.message
    assert_match wrong_did, error.message
  end

  test "create_account_on_new_pds succeeds when response has no DID field" do
    # Some PDS implementations may return a minimal response without a DID field.
    # The validation should only fire when a DID IS present but wrong.
    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.server.createAccount")
      .to_return(
        status: 200,
        body: {
          handle: @migration.new_handle,
          accessJwt: mock_jwt,
          refreshJwt: mock_jwt
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    assert_nothing_raised do
      @service.create_account_on_new_pds('test-service-auth-token')
    end
  end

  private

  def mock_jwt(exp: nil)
    exp ||= (Time.now.to_i + 3600)
    header = Base64.strict_encode64({ alg: 'HS256', typ: 'JWT' }.to_json)
    payload = Base64.strict_encode64({ sub: 'test', exp: exp }.to_json)
    signature = Base64.strict_encode64('mock-signature')
    "#{header}.#{payload}.#{signature}"
  end

  def stub_old_pds_login
    stub_request(:post, "#{@migration.old_pds_host}/xrpc/com.atproto.server.refreshSession")
      .to_return(status: 200, body: {
        did: @migration.did,
        handle: @migration.old_handle,
        accessJwt: mock_jwt,
        refreshJwt: mock_jwt(exp: 90.days.from_now.to_i)
      }.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  def stub_new_pds_login
    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.server.createSession")
      .to_return(status: 200, body: {
        did: @migration.did,
        handle: @migration.new_handle,
        accessJwt: mock_jwt,
        refreshJwt: mock_jwt
      }.to_json, headers: { 'Content-Type' => 'application/json' })
  end
end
