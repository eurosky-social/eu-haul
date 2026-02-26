require "test_helper"
require "webmock/minitest"

# Credential Handoff Integration Tests
#
# These tests verify the complete credential flow from form submission through
# to GoatService usage. This catches bugs where the controller stores one
# credential but GoatService expects another.
#
# The bug this would have caught:
#   - Controller stored a system-generated random password (for the new account)
#   - GoatService used that password to authenticate against the OLD PDS
#   - The old PDS would reject it because the user's real password is different
#
# The fix:
#   - Controller authenticates with the user's real password, captures session tokens
#   - Stores old PDS access_token + refresh_token (encrypted)
#   - GoatService uses token-based auth for old PDS (refresh → fresh access token)
#   - System-generated password is only used for the NEW PDS
class CredentialHandoffTest < ActiveSupport::TestCase
  def setup
    @old_pds_host = "https://oldpds.example.com"
    @new_pds_host = "https://newpds.example.com"
    @old_handle = "testuser.oldpds.com"
    @new_handle = "testuser.newpds.com"
    @did = "did:plc:handofftest123"
    @user_real_password = "users_real_p@ssword_456"
    @old_access_jwt = mock_jwt(exp: 30.seconds.from_now.to_i)  # Expired within 60s buffer so check_access triggers refresh
    @old_refresh_jwt = mock_jwt(exp: 90.days.from_now.to_i)

    WebMock.disable_net_connect!(allow_localhost: false)
  end

  def teardown
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  # ==========================================================================
  # Core credential handoff: controller → model → GoatService
  # ==========================================================================

  test "old PDS tokens from authentication are stored and used by GoatService" do
    # Step 1: Create migration the way the controller does it
    migration = Migration.create!(
      did: @did,
      old_handle: @old_handle,
      new_handle: @new_handle,
      old_pds_host: @old_pds_host,
      new_pds_host: @new_pds_host,
      email: "test@example.com",
      status: :pending_account
    )

    # Step 2: Store credentials the way the controller does
    # (simulating what happens after authenticate_and_fetch_profile)
    new_account_password = SecureRandom.urlsafe_base64(16)
    migration.password = new_account_password
    migration.credentials_expires_at = 48.hours.from_now
    migration.old_access_token = @old_access_jwt
    migration.old_refresh_token = @old_refresh_jwt
    migration.save!

    # Step 3: Verify the user's real password is NOT stored
    migration.reload
    assert_not_equal @user_real_password, migration.password,
      "The user's real password should NOT be stored — only the system-generated one"

    # Step 4: Verify old PDS tokens ARE stored
    assert_equal @old_access_jwt, migration.old_access_token,
      "Old PDS access token should be stored"
    assert_equal @old_refresh_jwt, migration.old_refresh_token,
      "Old PDS refresh token should be stored"

    # Step 5: Verify GoatService uses refresh token for old PDS (not password)
    refreshed_access_jwt = mock_jwt(exp: 1.hour.from_now.to_i)
    refreshed_refresh_jwt = mock_jwt(exp: 90.days.from_now.to_i)

    # This is the critical assertion: GoatService should call refreshSession
    # (with the stored refresh token), NOT createSession (with a password)
    refresh_stub = stub_request(:post, "#{@old_pds_host}/xrpc/com.atproto.server.refreshSession")
      .with(headers: { 'Authorization' => "Bearer #{@old_refresh_jwt}" })
      .to_return(status: 200, body: {
        did: @did,
        handle: @old_handle,
        accessJwt: refreshed_access_jwt,
        refreshJwt: refreshed_refresh_jwt
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    # createSession should NOT be called for the old PDS
    create_session_stub = stub_request(:post, "#{@old_pds_host}/xrpc/com.atproto.server.createSession")
      .to_return(status: 500, body: { error: "Should not be called" }.to_json)

    service = GoatService.new(migration)
    service.login_old_pds  # Public method that calls old_pds_client internally

    assert_requested(refresh_stub, times: 1)
    assert_not_requested(create_session_stub)

    # Verify tokens were persisted back to migration
    migration.reload
    assert_equal refreshed_access_jwt, migration.old_access_token,
      "Refreshed access token should be persisted"
    assert_equal refreshed_refresh_jwt, migration.old_refresh_token,
      "Refreshed refresh token should be persisted"
  end

  test "new PDS still uses system-generated password (not tokens)" do
    migration = create_test_migration

    # New PDS should use createSession with the system-generated password
    # Note: new_pds_client uses the DID as identifier, not the handle
    create_session_stub = stub_request(:post, "#{@new_pds_host}/xrpc/com.atproto.server.createSession")
      .with(body: hash_including(
        "identifier" => @did,
        "password" => migration.password
      ))
      .to_return(status: 200, body: {
        did: @did,
        handle: @new_handle,
        accessJwt: mock_jwt,
        refreshJwt: mock_jwt
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    service = GoatService.new(migration)
    service.login_new_pds  # Public method that calls new_pds_client internally

    assert_requested(create_session_stub, times: 1)
  end

  test "GoatService raises error when old PDS refresh token is missing" do
    migration = create_test_migration
    # Clear old PDS tokens to simulate the bug scenario
    migration.update!(
      encrypted_old_access_token: nil,
      encrypted_old_refresh_token: nil
    )
    migration.reload  # Flush Lockbox in-memory cache

    service = GoatService.new(migration)

    error = assert_raises(GoatService::AuthenticationError) do
      service.login_old_pds
    end

    assert_match /No old PDS refresh token available/, error.message
  end

  test "GoatService raises error when old PDS refresh token is expired" do
    migration = create_test_migration
    # Expire credentials
    migration.update!(credentials_expires_at: 1.hour.ago)

    service = GoatService.new(migration)

    # old_refresh_token returns nil when expired (via ExpirationChecks)
    assert_nil migration.old_refresh_token,
      "Old refresh token should return nil when credentials are expired"

    error = assert_raises(GoatService::AuthenticationError) do
      service.login_old_pds
    end

    assert_match /No old PDS refresh token available/, error.message
  end

  # ==========================================================================
  # Token rotation persistence across jobs
  # ==========================================================================

  test "token rotation is persisted when minisky refreshes automatically" do
    migration = create_test_migration

    # Initial refresh to create the client
    stub_request(:post, "#{@old_pds_host}/xrpc/com.atproto.server.refreshSession")
      .to_return(status: 200, body: {
        did: @did,
        handle: @old_handle,
        accessJwt: mock_jwt,
        refreshJwt: mock_jwt
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    service = GoatService.new(migration)
    service.login_old_pds

    # Get a reference to the client via send (private method, needed to test callback)
    client = service.send(:old_pds_client)

    # Simulate minisky triggering a token refresh (updates config and calls save_config)
    rotated_access = mock_jwt(exp: 2.hours.from_now.to_i)
    rotated_refresh = mock_jwt(exp: 90.days.from_now.to_i)
    client.config['access_token'] = rotated_access
    client.config['refresh_token'] = rotated_refresh
    client.save_config  # This triggers the on_token_refresh callback

    # Verify the rotated tokens were persisted to the database
    migration.reload
    assert_equal rotated_access, migration.old_access_token,
      "Rotated access token should be persisted via callback"
    assert_equal rotated_refresh, migration.old_refresh_token,
      "Rotated refresh token should be persisted via callback"
  end

  test "tokens survive across separate GoatService instances (simulating job chain)" do
    migration = create_test_migration

    # Job 1 gets a short-lived access token (expired by the time job 2 runs)
    refreshed_jwt_1 = mock_jwt(exp: 30.seconds.from_now.to_i)
    refreshed_refresh_1 = mock_jwt(exp: 90.days.from_now.to_i)

    # Job 1: Creates a GoatService, uses login_old_pds
    stub_request(:post, "#{@old_pds_host}/xrpc/com.atproto.server.refreshSession")
      .with(headers: { 'Authorization' => "Bearer #{@old_refresh_jwt}" })
      .to_return(status: 200, body: {
        did: @did,
        handle: @old_handle,
        accessJwt: refreshed_jwt_1,
        refreshJwt: refreshed_refresh_1
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    service1 = GoatService.new(migration)
    service1.login_old_pds

    # Verify tokens were updated
    migration.reload
    assert_equal refreshed_refresh_1, migration.old_refresh_token

    # Job 2: New GoatService instance, should use the refreshed token
    WebMock.reset!
    refreshed_jwt_2 = mock_jwt(exp: 2.hours.from_now.to_i)
    refreshed_refresh_2 = mock_jwt(exp: 90.days.from_now.to_i)

    refresh_stub_2 = stub_request(:post, "#{@old_pds_host}/xrpc/com.atproto.server.refreshSession")
      .with(headers: { 'Authorization' => "Bearer #{refreshed_refresh_1}" })
      .to_return(status: 200, body: {
        did: @did,
        handle: @old_handle,
        accessJwt: refreshed_jwt_2,
        refreshJwt: refreshed_refresh_2
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    service2 = GoatService.new(migration.reload)
    service2.login_old_pds

    # Should have used the REFRESHED token from job 1, not the original
    assert_requested(refresh_stub_2, times: 1)

    migration.reload
    assert_equal refreshed_jwt_2, migration.old_access_token
    assert_equal refreshed_refresh_2, migration.old_refresh_token
  end

  # ==========================================================================
  # Old PDS token cleanup after deactivation
  # ==========================================================================

  test "clear_old_pds_tokens removes tokens but leaves new PDS password" do
    migration = create_test_migration
    original_password = migration.password

    migration.clear_old_pds_tokens!

    migration.reload
    assert_nil migration.old_access_token, "Old access token should be cleared"
    assert_nil migration.old_refresh_token, "Old refresh token should be cleared"
    assert_equal original_password, migration.password,
      "New PDS password should still be available"
  end

  test "clear_credentials removes everything" do
    migration = create_test_migration

    migration.clear_credentials!

    migration.reload
    assert_nil migration.old_access_token
    assert_nil migration.old_refresh_token
    assert_nil migration.password
    assert_nil migration.credentials_expires_at
  end

  private

  def create_test_migration
    Migration.create!(
      did: @did,
      old_handle: @old_handle,
      new_handle: @new_handle,
      old_pds_host: @old_pds_host,
      new_pds_host: @new_pds_host,
      email: "test@example.com",
      status: :pending_account,
      credentials_expires_at: 48.hours.from_now
    ).tap do |m|
      m.password = SecureRandom.urlsafe_base64(16)
      m.old_access_token = @old_access_jwt
      m.old_refresh_token = @old_refresh_jwt
      m.save!
    end
  end

  def mock_jwt(exp: nil)
    exp ||= (Time.now.to_i + 3600)
    header = Base64.strict_encode64({ alg: 'HS256', typ: 'JWT' }.to_json)
    payload = Base64.strict_encode64({ sub: 'test', exp: exp }.to_json)
    signature = Base64.strict_encode64('mock-signature')
    "#{header}.#{payload}.#{signature}"
  end
end
