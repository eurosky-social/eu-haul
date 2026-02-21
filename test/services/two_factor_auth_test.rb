require "test_helper"
require "webmock/minitest"

# GoatService Two-Factor Authentication Tests
#
# Tests for 2FA (email-based auth factor token) support in GoatService.
# Bluesky PDS can require an email-based sign-in code when creating a session.
# When this happens, the PDS returns HTTP 401 with error "AuthFactorTokenRequired".
# The client must then retry createSession with the authFactorToken parameter.
class GoatServiceTwoFactorAuthTest < ActiveSupport::TestCase
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
  # TwoFactorRequiredError Class
  # ============================================================================

  test "TwoFactorRequiredError exists and inherits from GoatError" do
    assert defined?(GoatService::TwoFactorRequiredError),
      "TwoFactorRequiredError should be defined"
    assert GoatService::TwoFactorRequiredError < GoatService::GoatError,
      "TwoFactorRequiredError should inherit from GoatError"
  end

  # ============================================================================
  # create_direct_session with 2FA
  # ============================================================================

  test "create_direct_session raises TwoFactorRequiredError when PDS responds with AuthFactorTokenRequired" do
    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.server.createSession")
      .to_return(
        status: 401,
        body: { error: 'AuthFactorTokenRequired', message: 'Email sign-in code required' }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    error = assert_raises(GoatService::TwoFactorRequiredError) do
      @service.send(:create_direct_session,
        pds_host: @migration.new_pds_host,
        identifier: @migration.did
      )
    end

    assert_match /Two-factor authentication is required/, error.message
  end

  test "create_direct_session succeeds with auth_factor_token when 2FA code is provided" do
    expected_token = "123456"

    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.server.createSession")
      .with(body: hash_including(
        "identifier" => @migration.did,
        "password" => @migration.password,
        "authFactorToken" => expected_token
      ))
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

    result = @service.send(:create_direct_session,
      pds_host: @migration.new_pds_host,
      identifier: @migration.did,
      auth_factor_token: expected_token
    )

    assert result.present?, "Should return an access token"
  end

  test "create_direct_session without 2FA works normally for non-2FA accounts" do
    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.server.createSession")
      .with(body: hash_including(
        "identifier" => @migration.did,
        "password" => @migration.password
      ))
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

    result = @service.send(:create_direct_session,
      pds_host: @migration.new_pds_host,
      identifier: @migration.did
    )

    assert result.present?, "Should return an access token without 2FA"
  end

  test "TwoFactorRequiredError is not caught by generic StandardError rescue and re-raises properly" do
    # The create_direct_session method has a rescue StandardError that wraps
    # errors in AuthenticationError. TwoFactorRequiredError must be re-raised
    # before that catch-all so callers can distinguish it.
    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.server.createSession")
      .to_return(
        status: 401,
        body: { error: 'AuthFactorTokenRequired', message: 'Email sign-in code required' }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )

    # It must raise TwoFactorRequiredError specifically, not AuthenticationError
    error = assert_raises(GoatService::TwoFactorRequiredError) do
      @service.send(:create_direct_session,
        pds_host: @migration.new_pds_host,
        identifier: @migration.did
      )
    end

    # Verify it's the exact class, not a parent
    assert_equal GoatService::TwoFactorRequiredError, error.class,
      "Should raise TwoFactorRequiredError, not a parent class like AuthenticationError"
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
