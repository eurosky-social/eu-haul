require "test_helper"
require "webmock/minitest"

# MigrationsController Two-Factor Authentication Tests
#
# Tests for 2FA support in the lookup_handle and verify_target_credentials
# controller actions. These are AJAX endpoints that the migration wizard calls
# during the initial authentication step.
#
# When a Bluesky PDS has email-based 2FA enabled, createSession returns
# HTTP 401 with error "AuthFactorTokenRequired". The controller must:
# 1. Detect this and return { two_factor_required: true } to the frontend
# 2. Accept a two_factor_code param on retry and pass it through as authFactorToken
class MigrationsControllerTwoFactorTest < ActionDispatch::IntegrationTest
  def setup
    WebMock.disable_net_connect!(allow_localhost: false)

    @test_handle = "user.bsky.social"
    @test_password = "test_password_123"
    @test_did = "did:plc:test2fa456"
    @test_pds_host = "https://bsky.social"
    @test_email = "user@example.com"
  end

  def teardown
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  # ============================================================================
  # lookup_handle with 2FA
  # ============================================================================

  test "lookup_handle returns two_factor_required when 2FA is needed" do
    # Stub handle resolution (class methods called before authentication)
    GoatService.stubs(:clean_handle).with(@test_handle).returns(@test_handle)
    GoatService.stubs(:detect_handle_type).with(@test_handle).returns({
      type: 'pds_hosted',
      verified_via: 'pds_api',
      can_preserve: false,
      reason: 'PDS-hosted handle'
    })
    GoatService.stubs(:resolve_handle).with(@test_handle).returns({
      did: @test_did,
      pds_host: @test_pds_host
    })

    # Stub createSession to return AuthFactorTokenRequired
    stub_request(:post, "#{@test_pds_host}/xrpc/com.atproto.server.createSession")
      .with(body: hash_including(
        "identifier" => @test_handle,
        "password" => @test_password
      ))
      .to_return(
        status: 401,
        body: { error: 'AuthFactorTokenRequired', message: 'Email sign-in code required' }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    post lookup_handle_migrations_path, params: {
      handle: @test_handle,
      password: @test_password
    }, as: :json

    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert json['two_factor_required'], "Response should indicate two_factor_required"
    assert json['error'].present?, "Response should include an error message"
  end

  test "lookup_handle succeeds when two_factor_code is provided" do
    two_factor_code = "123456"

    GoatService.stubs(:clean_handle).with(@test_handle).returns(@test_handle)
    GoatService.stubs(:detect_handle_type).with(@test_handle).returns({
      type: 'pds_hosted',
      verified_via: 'pds_api',
      can_preserve: false,
      reason: 'PDS-hosted handle'
    })
    GoatService.stubs(:resolve_handle).with(@test_handle).returns({
      did: @test_did,
      pds_host: @test_pds_host
    })

    # Stub createSession to accept the authFactorToken and return success
    stub_request(:post, "#{@test_pds_host}/xrpc/com.atproto.server.createSession")
      .with(body: hash_including(
        "identifier" => @test_handle,
        "password" => @test_password,
        "authFactorToken" => two_factor_code
      ))
      .to_return(
        status: 200,
        body: {
          did: @test_did,
          handle: @test_handle,
          email: @test_email,
          accessJwt: mock_jwt,
          refreshJwt: mock_jwt
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    post lookup_handle_migrations_path, params: {
      handle: @test_handle,
      password: @test_password,
      two_factor_code: two_factor_code
    }, as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal @test_did, json['did']
    assert_equal @test_email, json['email']
    assert json['access_token'].present?, "Response should include access_token"
    assert json['refresh_token'].present?, "Response should include refresh_token"
  end

  # ============================================================================
  # verify_target_credentials with 2FA
  # ============================================================================

  test "verify_target_credentials returns two_factor_required when 2FA is needed" do
    target_pds = "https://bsky.social"

    stub_request(:post, "#{target_pds}/xrpc/com.atproto.server.createSession")
      .with(body: hash_including(
        "identifier" => @test_did,
        "password" => @test_password
      ))
      .to_return(
        status: 401,
        body: { error: 'AuthFactorTokenRequired', message: 'Email sign-in code required' }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    post verify_target_credentials_migrations_path, params: {
      pds_host: target_pds,
      did: @test_did,
      password: @test_password
    }, as: :json

    assert_response :unauthorized
    json = JSON.parse(response.body)
    assert json['two_factor_required'], "Response should indicate two_factor_required"
    assert_match /Two-factor authentication required/, json['error']
  end

  test "verify_target_credentials succeeds with two_factor_code" do
    target_pds = "https://bsky.social"
    two_factor_code = "654321"

    stub_request(:post, "#{target_pds}/xrpc/com.atproto.server.createSession")
      .with(body: hash_including(
        "identifier" => @test_did,
        "password" => @test_password,
        "authFactorToken" => two_factor_code
      ))
      .to_return(
        status: 200,
        body: {
          did: @test_did,
          handle: @test_handle,
          accessJwt: mock_jwt,
          refreshJwt: mock_jwt
        }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    post verify_target_credentials_migrations_path, params: {
      pds_host: target_pds,
      did: @test_did,
      password: @test_password,
      two_factor_code: two_factor_code
    }, as: :json

    assert_response :success
    json = JSON.parse(response.body)
    assert json['success'], "Response should indicate success"
    assert json['access_token'].present?, "Response should include access_token"
    assert json['refresh_token'].present?, "Response should include refresh_token"
  end

  private

  def mock_jwt(exp: nil)
    exp ||= (Time.now.to_i + 3600)
    header = Base64.strict_encode64({ alg: 'HS256', typ: 'JWT' }.to_json)
    payload = Base64.strict_encode64({ sub: 'test', exp: exp }.to_json)
    signature = Base64.strict_encode64('mock-signature')
    "#{header}.#{payload}.#{signature}"
  end
end
