require "test_helper"
require "webmock/minitest"

# GoatService Session Reuse Tests
#
# Verifies that GoatService properly reuses access tokens across jobs
# instead of creating a new session for every action:
#
# 1. Valid stored access tokens are reused without any API call
# 2. Expired access tokens trigger a refresh via minisky (not a full login)
# 3. Missing access tokens trigger a refresh via TokenPdsClient.check_access
# 4. Password-based login (migration_out) persists tokens for subsequent jobs
# 5. Multiple methods within the same GoatService instance share one session
# 6. Sequential GoatService instances (simulating job chain) reuse tokens
class GoatServiceSessionReuseTest < ActiveSupport::TestCase
  def setup
    @old_pds_host = "https://oldpds.example.com"
    @new_pds_host = "https://newpds.example.com"
    @did = "did:plc:sessiontest123"

    WebMock.disable_net_connect!(allow_localhost: false)
  end

  def teardown
    WebMock.reset!
    WebMock.allow_net_connect!
  end

  # ============================================================================
  # Old PDS: Access token reuse
  # ============================================================================

  test "old PDS: reuses stored access token when still valid (no API call)" do
    migration = create_migration(
      old_access_token: mock_jwt(exp: 5.minutes.from_now.to_i),
      old_refresh_token: mock_jwt(exp: 90.days.from_now.to_i)
    )

    # No HTTP stubs — if any API call is made, WebMock will raise
    service = GoatService.new(migration)
    service.login_old_pds

    # Verify the token is available
    client = service.send(:old_pds_client)
    assert client.config['access_token'].present?
  end

  test "old PDS: refreshes when stored access token is expired" do
    expired_access = mock_jwt(exp: 30.seconds.from_now.to_i)  # Within 60s buffer = expired
    old_refresh = mock_jwt(exp: 90.days.from_now.to_i)
    fresh_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    fresh_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    migration = create_migration(
      old_access_token: expired_access,
      old_refresh_token: old_refresh
    )

    refresh_stub = stub_request(:post, "#{@old_pds_host}/xrpc/com.atproto.server.refreshSession")
      .with(headers: { 'Authorization' => "Bearer #{old_refresh}" })
      .to_return(status: 200, body: {
        did: @did, handle: 'user.oldpds.com',
        accessJwt: fresh_access, refreshJwt: fresh_refresh
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    service = GoatService.new(migration)
    service.login_old_pds

    assert_requested(refresh_stub, times: 1)

    # Verify fresh token is now in the client
    client = service.send(:old_pds_client)
    assert_equal fresh_access, client.config['access_token']

    # Verify persisted to DB
    migration.reload
    assert_equal fresh_access, migration.old_access_token
    assert_equal fresh_refresh, migration.old_refresh_token
  end

  test "old PDS: refreshes when no access token is stored (only refresh token)" do
    old_refresh = mock_jwt(exp: 90.days.from_now.to_i)
    fresh_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    fresh_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    migration = create_migration(
      old_access_token: nil,
      old_refresh_token: old_refresh
    )

    refresh_stub = stub_request(:post, "#{@old_pds_host}/xrpc/com.atproto.server.refreshSession")
      .to_return(status: 200, body: {
        did: @did, handle: 'user.oldpds.com',
        accessJwt: fresh_access, refreshJwt: fresh_refresh
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    service = GoatService.new(migration)
    service.login_old_pds

    assert_requested(refresh_stub, times: 1)

    client = service.send(:old_pds_client)
    assert_equal fresh_access, client.config['access_token']
  end

  test "old PDS: single session shared across multiple method calls" do
    old_refresh = mock_jwt(exp: 90.days.from_now.to_i)
    fresh_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    fresh_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    migration = create_migration(
      old_access_token: nil,
      old_refresh_token: old_refresh
    )

    refresh_stub = stub_request(:post, "#{@old_pds_host}/xrpc/com.atproto.server.refreshSession")
      .to_return(status: 200, body: {
        did: @did, handle: 'user.oldpds.com',
        accessJwt: fresh_access, refreshJwt: fresh_refresh
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    # Stub an API call that login_old_pds + export_preferences would both need
    stub_request(:get, /#{Regexp.escape(@old_pds_host)}.*app\.bsky\.actor\.getPreferences/)
      .to_return(status: 200, body: { preferences: [] }.to_json, headers: { 'Content-Type' => 'application/json' })

    service = GoatService.new(migration)

    # Call login_old_pds twice and export_preferences (all need old_pds_client)
    service.login_old_pds
    service.login_old_pds
    service.export_preferences

    # Only ONE refresh should have been made (the ||= cache works)
    assert_requested(refresh_stub, times: 1)
  end

  # ============================================================================
  # New PDS (migration_out): Password login + token persistence
  # ============================================================================

  test "new PDS migration_out: first job uses password login and persists tokens" do
    migration = create_migration(
      new_access_token: nil,
      new_refresh_token: nil
    )

    new_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    new_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    create_session_stub = stub_request(:post, "#{@new_pds_host}/xrpc/com.atproto.server.createSession")
      .with(body: hash_including("identifier" => @did, "password" => migration.password))
      .to_return(status: 200, body: {
        did: @did, handle: 'user.newpds.com',
        accessJwt: new_access, refreshJwt: new_refresh
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    service = GoatService.new(migration)
    service.login_new_pds

    assert_requested(create_session_stub, times: 1)

    # Verify tokens were persisted for next job
    migration.reload
    assert_equal new_access, migration.new_access_token
    assert_equal new_refresh, migration.new_refresh_token
  end

  test "new PDS migration_out: second job reuses stored token (no password login)" do
    # Simulate first job having persisted tokens
    valid_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    stored_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    migration = create_migration(
      new_access_token: valid_access,
      new_refresh_token: stored_refresh
    )

    # Password-based createSession should NOT be called
    create_session_stub = stub_request(:post, "#{@new_pds_host}/xrpc/com.atproto.server.createSession")
      .to_return(status: 500, body: { error: "Should not be called" }.to_json)

    # refreshSession should NOT be called either (token is still valid)
    refresh_stub = stub_request(:post, "#{@new_pds_host}/xrpc/com.atproto.server.refreshSession")
      .to_return(status: 500, body: { error: "Should not be called" }.to_json)

    service = GoatService.new(migration)
    service.login_new_pds

    assert_not_requested(create_session_stub)
    assert_not_requested(refresh_stub)
  end

  test "new PDS migration_out: second job refreshes if stored token expired" do
    expired_access = mock_jwt(exp: 30.seconds.from_now.to_i)  # Within 60s buffer
    stored_refresh = mock_jwt(exp: 90.days.from_now.to_i)
    fresh_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    fresh_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    migration = create_migration(
      new_access_token: expired_access,
      new_refresh_token: stored_refresh
    )

    # Should use refreshSession, NOT createSession
    create_session_stub = stub_request(:post, "#{@new_pds_host}/xrpc/com.atproto.server.createSession")
      .to_return(status: 500, body: { error: "Should not be called" }.to_json)

    refresh_stub = stub_request(:post, "#{@new_pds_host}/xrpc/com.atproto.server.refreshSession")
      .with(headers: { 'Authorization' => "Bearer #{stored_refresh}" })
      .to_return(status: 200, body: {
        did: @did, handle: 'user.newpds.com',
        accessJwt: fresh_access, refreshJwt: fresh_refresh
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    service = GoatService.new(migration)
    service.login_new_pds

    assert_not_requested(create_session_stub)
    assert_requested(refresh_stub, times: 1)

    migration.reload
    assert_equal fresh_access, migration.new_access_token
    assert_equal fresh_refresh, migration.new_refresh_token
  end

  # ============================================================================
  # New PDS (migration_in): Token-based auth
  # ============================================================================

  test "new PDS migration_in: reuses stored access token when valid" do
    valid_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    stored_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    migration = create_migration(
      migration_type: :migration_in,
      new_pds_host: "https://bsky.social",
      new_handle: "user.bsky.social",
      new_access_token: valid_access,
      new_refresh_token: stored_refresh
    )

    # No API calls should be made
    service = GoatService.new(migration)
    service.login_new_pds

    client = service.send(:new_pds_client)
    assert_equal valid_access, client.config['access_token']
  end

  test "new PDS migration_in: refreshes when access token expired" do
    expired_access = mock_jwt(exp: 30.seconds.from_now.to_i)
    stored_refresh = mock_jwt(exp: 90.days.from_now.to_i)
    fresh_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    fresh_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    migration = create_migration(
      migration_type: :migration_in,
      new_pds_host: "https://bsky.social",
      new_handle: "user.bsky.social",
      new_access_token: expired_access,
      new_refresh_token: stored_refresh
    )

    refresh_stub = stub_request(:post, "https://bsky.social/xrpc/com.atproto.server.refreshSession")
      .with(headers: { 'Authorization' => "Bearer #{stored_refresh}" })
      .to_return(status: 200, body: {
        did: @did, handle: 'user.bsky.social',
        accessJwt: fresh_access, refreshJwt: fresh_refresh
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    service = GoatService.new(migration)
    service.login_new_pds

    assert_requested(refresh_stub, times: 1)

    migration.reload
    assert_equal fresh_access, migration.new_access_token
  end

  # ============================================================================
  # Cross-job token reuse (simulating sequential Sidekiq jobs)
  # ============================================================================

  test "job chain: tokens from job 1 are reused by job 2 without API calls" do
    old_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    migration = create_migration(
      old_access_token: nil,
      old_refresh_token: old_refresh,
      new_access_token: nil,
      new_refresh_token: nil
    )

    # --- Job 1: First-time setup ---
    job1_old_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    job1_old_refresh = mock_jwt(exp: 90.days.from_now.to_i)
    job1_new_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    job1_new_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    stub_request(:post, "#{@old_pds_host}/xrpc/com.atproto.server.refreshSession")
      .to_return(status: 200, body: {
        did: @did, handle: 'user.oldpds.com',
        accessJwt: job1_old_access, refreshJwt: job1_old_refresh
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    stub_request(:post, "#{@new_pds_host}/xrpc/com.atproto.server.createSession")
      .to_return(status: 200, body: {
        did: @did, handle: 'user.newpds.com',
        accessJwt: job1_new_access, refreshJwt: job1_new_refresh
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    service1 = GoatService.new(migration)
    service1.login_old_pds
    service1.login_new_pds

    # Verify job 1 persisted tokens
    migration.reload
    assert_equal job1_old_access, migration.old_access_token
    assert_equal job1_old_refresh, migration.old_refresh_token
    assert_equal job1_new_access, migration.new_access_token
    assert_equal job1_new_refresh, migration.new_refresh_token

    # --- Job 2: Should reuse tokens without any API calls ---
    WebMock.reset!
    WebMock.disable_net_connect!(allow_localhost: false)

    # No stubs — any API call will cause WebMock to raise an error
    service2 = GoatService.new(migration.reload)
    service2.login_old_pds
    service2.login_new_pds

    # If we got here, no API calls were made — tokens were reused!
    old_client = service2.send(:old_pds_client)
    new_client = service2.send(:new_pds_client)
    assert_equal job1_old_access, old_client.config['access_token']
    assert_equal job1_new_access, new_client.config['access_token']
  end

  test "job chain: expired tokens from job 1 are refreshed (not re-logged-in) by job 2" do
    old_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    migration = create_migration(
      old_access_token: nil,
      old_refresh_token: old_refresh
    )

    # --- Job 1: Gets tokens with short expiry (simulating time passing) ---
    job1_old_access = mock_jwt(exp: 30.seconds.from_now.to_i)  # Will be "expired" for job 2
    job1_old_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    stub_request(:post, "#{@old_pds_host}/xrpc/com.atproto.server.refreshSession")
      .to_return(status: 200, body: {
        did: @did, handle: 'user.oldpds.com',
        accessJwt: job1_old_access, refreshJwt: job1_old_refresh
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    service1 = GoatService.new(migration)
    service1.login_old_pds

    migration.reload
    assert_equal job1_old_refresh, migration.old_refresh_token

    # --- Job 2: Access token is expired, should refresh using stored refresh token ---
    WebMock.reset!
    WebMock.disable_net_connect!(allow_localhost: false)

    job2_old_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    job2_old_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    refresh_stub = stub_request(:post, "#{@old_pds_host}/xrpc/com.atproto.server.refreshSession")
      .with(headers: { 'Authorization' => "Bearer #{job1_old_refresh}" })
      .to_return(status: 200, body: {
        did: @did, handle: 'user.oldpds.com',
        accessJwt: job2_old_access, refreshJwt: job2_old_refresh
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    service2 = GoatService.new(migration.reload)
    service2.login_old_pds

    assert_requested(refresh_stub, times: 1)

    migration.reload
    assert_equal job2_old_access, migration.old_access_token
    assert_equal job2_old_refresh, migration.old_refresh_token
  end

  # ============================================================================
  # TokenPdsClient.check_access override
  # ============================================================================

  test "TokenPdsClient.check_access refreshes when access_token is nil" do
    refresh_token = mock_jwt(exp: 90.days.from_now.to_i)
    fresh_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    fresh_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    persisted_tokens = {}

    client = TokenPdsClient.new(
      @old_pds_host,
      'user.oldpds.com',
      access_token: nil,
      refresh_token: refresh_token,
      on_token_refresh: ->(access, refresh) {
        persisted_tokens[:access] = access
        persisted_tokens[:refresh] = refresh
      }
    )

    stub_request(:post, "#{@old_pds_host}/xrpc/com.atproto.server.refreshSession")
      .with(headers: { 'Authorization' => "Bearer #{refresh_token}" })
      .to_return(status: 200, body: {
        did: @did, handle: 'user.oldpds.com',
        accessJwt: fresh_access, refreshJwt: fresh_refresh
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    client.check_access

    assert_equal fresh_access, client.config['access_token']
    assert_equal fresh_refresh, client.config['refresh_token']

    # Verify callback persisted the tokens
    assert_equal fresh_access, persisted_tokens[:access]
    assert_equal fresh_refresh, persisted_tokens[:refresh]
  end

  test "TokenPdsClient.check_access is a no-op when access_token is still valid" do
    valid_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    refresh_token = mock_jwt(exp: 90.days.from_now.to_i)

    client = TokenPdsClient.new(
      @old_pds_host,
      'user.oldpds.com',
      access_token: valid_access,
      refresh_token: refresh_token
    )

    # No stubs — if any API call is made, WebMock will raise
    client.check_access

    assert_equal valid_access, client.config['access_token']
  end

  test "TokenPdsClient.check_access refreshes when access_token is expired" do
    expired_access = mock_jwt(exp: 30.seconds.from_now.to_i)
    refresh_token = mock_jwt(exp: 90.days.from_now.to_i)
    fresh_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    fresh_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    client = TokenPdsClient.new(
      @old_pds_host,
      'user.oldpds.com',
      access_token: expired_access,
      refresh_token: refresh_token
    )

    stub_request(:post, "#{@old_pds_host}/xrpc/com.atproto.server.refreshSession")
      .to_return(status: 200, body: {
        did: @did, handle: 'user.oldpds.com',
        accessJwt: fresh_access, refreshJwt: fresh_refresh
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    client.check_access

    assert_equal fresh_access, client.config['access_token']
  end

  # ============================================================================
  # Direct HTTP calls get valid tokens
  # ============================================================================

  test "upload_blob_request uses access token from new_pds_client" do
    valid_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    stored_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    migration = create_migration(
      new_access_token: valid_access,
      new_refresh_token: stored_refresh
    )

    service = GoatService.new(migration)

    # Create a temp blob file
    Dir.mktmpdir("goat_upload_test") do |tmpdir|
      blob_path = File.join(tmpdir, 'test_blob')
      File.binwrite(blob_path, 'test blob data')

      # Verify the upload uses the stored access token
      upload_stub = stub_request(:post, "#{@new_pds_host}/xrpc/com.atproto.repo.uploadBlob")
        .with(headers: { 'Authorization' => "Bearer #{valid_access}" })
        .to_return(status: 200, body: { blob: { ref: { '$link' => 'bafytest' } } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      service.send(:upload_blob_request, blob_path)

      assert_requested(upload_stub, times: 1)
    end
  end

  test "upload_blob_request retries with refreshed token on 401" do
    expired_access = mock_jwt(exp: 30.seconds.from_now.to_i)
    stored_refresh = mock_jwt(exp: 90.days.from_now.to_i)
    fresh_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    fresh_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    migration = create_migration(
      new_access_token: expired_access,
      new_refresh_token: stored_refresh
    )

    # Stub refresh for when check_access is called eagerly during client creation
    stub_request(:post, "#{@new_pds_host}/xrpc/com.atproto.server.refreshSession")
      .to_return(status: 200, body: {
        did: @did, handle: 'user.newpds.com',
        accessJwt: fresh_access, refreshJwt: fresh_refresh
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    service = GoatService.new(migration)

    Dir.mktmpdir("goat_upload_test") do |tmpdir|
      blob_path = File.join(tmpdir, 'test_blob')
      File.binwrite(blob_path, 'test blob data')

      # First call returns 401, second (after refresh) succeeds
      call_count = 0
      stub_request(:post, "#{@new_pds_host}/xrpc/com.atproto.repo.uploadBlob")
        .to_return do |_request|
          call_count += 1
          if call_count == 1
            { status: 401, body: { error: 'ExpiredToken' }.to_json }
          else
            { status: 200, body: { blob: { ref: { '$link' => 'bafytest' } } }.to_json,
              headers: { 'Content-Type' => 'application/json' } }
          end
        end

      result = service.send(:upload_blob_request, blob_path)

      assert_equal 'bafytest', result['blob']['ref']['$link']
      assert_equal 2, call_count, "Should have retried after 401"
    end
  end

  # ============================================================================
  # login_new_pds caching (no longer clears client on each call)
  # ============================================================================

  test "login_new_pds called multiple times only creates one session" do
    migration = create_migration(
      new_access_token: nil,
      new_refresh_token: nil
    )

    new_access = mock_jwt(exp: 5.minutes.from_now.to_i)
    new_refresh = mock_jwt(exp: 90.days.from_now.to_i)

    create_session_stub = stub_request(:post, "#{@new_pds_host}/xrpc/com.atproto.server.createSession")
      .to_return(status: 200, body: {
        did: @did, handle: 'user.newpds.com',
        accessJwt: new_access, refreshJwt: new_refresh
      }.to_json, headers: { 'Content-Type' => 'application/json' })

    service = GoatService.new(migration)
    service.login_new_pds
    service.login_new_pds
    service.login_new_pds

    # Should only have logged in once thanks to ||= caching
    assert_requested(create_session_stub, times: 1)
  end

  private

  def create_migration(
    old_access_token: mock_jwt(exp: 5.minutes.from_now.to_i),
    old_refresh_token: mock_jwt(exp: 90.days.from_now.to_i),
    new_access_token: nil,
    new_refresh_token: nil,
    migration_type: :migration_out,
    new_pds_host: @new_pds_host,
    new_handle: "user.newpds.com"
  )
    migration = Migration.create!(
      did: @did,
      old_handle: "user.oldpds.com",
      new_handle: new_handle,
      old_pds_host: @old_pds_host,
      new_pds_host: new_pds_host,
      email: "session-test@example.com",
      status: :pending_account,
      migration_type: migration_type,
      credentials_expires_at: 48.hours.from_now
    )

    migration.password = SecureRandom.urlsafe_base64(16)
    migration.old_access_token = old_access_token if old_access_token
    migration.old_refresh_token = old_refresh_token if old_refresh_token
    migration.new_access_token = new_access_token if new_access_token
    migration.new_refresh_token = new_refresh_token if new_refresh_token
    migration.save!

    migration
  end

  def mock_jwt(exp: nil)
    exp ||= (Time.now.to_i + 3600)
    header = Base64.strict_encode64({ alg: 'HS256', typ: 'JWT' }.to_json)
    payload = Base64.strict_encode64({ sub: 'test', exp: exp }.to_json)
    signature = Base64.strict_encode64('mock-signature')
    "#{header}.#{payload}.#{signature}"
  end
end
