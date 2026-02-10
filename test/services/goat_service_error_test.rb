require "test_helper"

# GoatService Error Handling Tests
# Tests based on MIGRATION_ERROR_ANALYSIS.md covering all possible errors
# across all migration stages
class GoatServiceErrorTest < ActiveSupport::TestCase
  def setup
    @migration = migrations(:pending_migration)
    @service = GoatService.new(@migration)
  end

  # ============================================================================
  # Stage 2: Authentication Errors
  # ============================================================================

  test "login_old_pds raises AuthenticationError on wrong password" do
    stub_goat_command_failure(
      ['account', 'login', '--pds-host', @migration.old_pds_host,
       '-u', @migration.old_handle, '-p', @migration.password],
      "authentication failed: invalid password"
    )

    error = assert_raises(GoatService::AuthenticationError) do
      @service.login_old_pds
    end

    assert_match /Failed to login to old PDS/, error.message
    assert_match /invalid password/, error.message
  end

  test "login_old_pds raises AuthenticationError when PDS unreachable" do
    stub_goat_command_failure(
      ['account', 'login', '--pds-host', @migration.old_pds_host,
       '-u', @migration.old_handle, '-p', @migration.password],
      "connection refused"
    )

    error = assert_raises(GoatService::AuthenticationError) do
      @service.login_old_pds
    end

    assert_match /Failed to login to old PDS/, error.message
  end

  test "login_new_pds raises AuthenticationError on credentials expired" do
    @migration.update!(credentials_expires_at: 1.hour.ago)

    # Password should return nil due to expiration
    assert_nil @migration.password

    stub_goat_command_failure(
      ['account', 'login', '--pds-host', @migration.new_pds_host,
       '-u', @migration.did, '-p', nil],
      "invalid credentials"
    )

    error = assert_raises(GoatService::AuthenticationError) do
      @service.login_new_pds
    end

    assert_match /Failed to login to new PDS/, error.message
  end

  # ============================================================================
  # Stage 2: Account Creation Errors
  # ============================================================================

  test "get_service_auth_token raises AuthenticationError on failure" do
    stub_goat_command_success(['account', 'login'], "", "")

    stub_goat_command_failure(
      ['account', 'service-auth', '--lxm', 'com.atproto.server.createAccount',
       '--aud', 'did:web:newpds.com', '--duration-sec', '3600'],
      "service auth denied"
    )

    error = assert_raises(GoatService::AuthenticationError) do
      @service.get_service_auth_token('did:web:newpds.com')
    end

    assert_match /Failed to get service auth token/, error.message
  end

  test "get_service_auth_token raises error on empty token" do
    stub_goat_command_success(
      ['account', 'service-auth', '--lxm', 'com.atproto.server.createAccount',
       '--aud', 'did:web:newpds.com', '--duration-sec', '3600'],
      "", # Empty stdout
      ""
    )

    error = assert_raises(GoatService::GoatError) do
      @service.get_service_auth_token('did:web:newpds.com')
    end

    assert_match /Empty service auth token/, error.message
  end

  test "check_account_exists_on_new_pds detects orphaned deactivated account" do
    stub_http_get(
      "#{@migration.new_pds_host}/xrpc/com.atproto.repo.describeRepo?repo=#{@migration.did}",
      { error: 'RepoDeactivated' }.to_json
    )

    result = @service.check_account_exists_on_new_pds

    assert result[:exists]
    assert result[:deactivated]
  end

  test "check_account_exists_on_new_pds detects active existing account" do
    stub_http_get(
      "#{@migration.new_pds_host}/xrpc/com.atproto.repo.describeRepo?repo=#{@migration.did}",
      { did: @migration.did, handle: 'existing.handle.com' }.to_json
    )

    result = @service.check_account_exists_on_new_pds

    assert result[:exists]
    assert_not result[:deactivated]
    assert_equal 'existing.handle.com', result[:handle]
  end

  test "create_account_on_new_pds raises AccountExistsError for orphaned account" do
    # Stub account creation to fail with AlreadyExists
    stub_goat_command_failure(
      ['account', 'create', '--pds-host', @migration.new_pds_host,
       '--existing-did', @migration.did, '--handle', @migration.new_handle,
       '--password', @migration.password, '--email', @migration.email,
       '--service-auth', 'test-token'],
      "AlreadyExists: Repo already exists"
    )

    # Stub check to confirm deactivated account
    stub_http_get(
      "#{@migration.new_pds_host}/xrpc/com.atproto.repo.describeRepo?repo=#{@migration.did}",
      { error: 'RepoDeactivated' }.to_json
    )

    error = assert_raises(GoatService::AccountExistsError) do
      @service.create_account_on_new_pds('test-token')
    end

    assert_match /Orphaned deactivated account/, error.message
    assert_match /delete the account from the PDS database/, error.message
  end

  test "create_account_on_new_pds raises AccountExistsError for active account" do
    stub_goat_command_failure(
      ['account', 'create'],
      "AlreadyExists: Account already active"
    )

    stub_http_get(
      "#{@migration.new_pds_host}/xrpc/com.atproto.repo.describeRepo?repo=#{@migration.did}",
      { did: @migration.did, handle: 'existing.handle.com' }.to_json
    )

    error = assert_raises(GoatService::AccountExistsError) do
      @service.create_account_on_new_pds('test-token')
    end

    assert_match /Active account already exists/, error.message
  end

  test "create_account_on_new_pds includes invite code when present" do
    @migration.set_invite_code('test-invite-code')

    # Expect the invite code to be included in the command
    stub_goat_command_success(
      ['account', 'create', '--pds-host', @migration.new_pds_host,
       '--existing-did', @migration.did, '--handle', @migration.new_handle,
       '--password', @migration.password, '--email', @migration.email,
       '--service-auth', 'test-token', '--invite-code', 'test-invite-code'],
      "Account created",
      ""
    )

    assert_nothing_raised do
      @service.create_account_on_new_pds('test-token')
    end
  end

  test "create_account_on_new_pds raises GoatError for invalid invite code" do
    @migration.set_invite_code('invalid-code')

    stub_goat_command_failure(
      ['account', 'create'],
      "InvalidInviteCode: Invite code is invalid or expired"
    )

    error = assert_raises(GoatService::GoatError) do
      @service.create_account_on_new_pds('test-token')
    end

    assert_match /Failed to create account/, error.message
    assert_match /invite code is invalid/, error.message
  end

  # ============================================================================
  # Stage 2: Rate Limiting Errors
  # ============================================================================

  test "login_old_pds raises RateLimitError on HTTP 429" do
    stub_goat_command_failure(
      ['account', 'login'],
      "HTTP 429: Too Many Requests"
    )

    error = assert_raises(GoatService::RateLimitError) do
      @service.login_old_pds
    end

    assert_match /PDS rate limit exceeded/, error.message
  end

  test "rate_limit_error? detects various rate limit indicators" do
    rate_limit_messages = [
      "HTTP 429: Too Many Requests",
      "RateLimitExceeded",
      "rate limit exceeded",
      "API request failed (HTTP 429)"
    ]

    rate_limit_messages.each do |msg|
      assert @service.send(:rate_limit_error?, msg),
        "Should detect rate limit in: #{msg}"
    end
  end

  test "rate_limit_error? returns false for non-rate-limit errors" do
    non_rate_limit_messages = [
      "HTTP 401: Unauthorized",
      "connection refused",
      "timeout"
    ]

    non_rate_limit_messages.each do |msg|
      assert_not @service.send(:rate_limit_error?, msg),
        "Should not detect rate limit in: #{msg}"
    end
  end

  # ============================================================================
  # Stage 3: Repository Export/Import Errors
  # ============================================================================

  test "export_repo raises GoatError on timeout" do
    stub_goat_command_success(['account', 'login'], "", "")

    # Stub the curl command to simulate timeout
    stub_command_timeout(
      ['curl', '-s', '-f', '--max-time', '600'],
      timeout: 660
    )

    error = assert_raises(GoatService::TimeoutError) do
      @service.export_repo
    end

    assert_match /Command timed out/, error.message
  end

  test "export_repo raises GoatError when CAR file empty" do
    stub_goat_command_success(['account', 'login'], "", "")

    # Stub curl to create empty file
    car_path = @service.work_dir.join("account.#{Time.now.to_i}.car")
    stub_command_success(['curl'], "", "") do
      FileUtils.touch(car_path) # Create empty file
    end

    error = assert_raises(GoatService::GoatError) do
      @service.export_repo
    end

    assert_match /file not created or empty/, error.message
  end

  test "import_repo raises GoatError when CAR file not found" do
    error = assert_raises(GoatService::GoatError) do
      @service.import_repo('/nonexistent/path.car')
    end

    assert_match /CAR file not found/, error.message
  end

  test "import_repo raises GoatError on import failure" do
    car_path = @service.work_dir.join('test.car')
    File.write(car_path, 'test data')

    stub_goat_command_success(['account', 'login'], "", "")
    stub_goat_command_failure(
      ['repo', 'import', car_path.to_s],
      "invalid CAR format"
    )

    error = assert_raises(GoatService::GoatError) do
      @service.import_repo(car_path.to_s)
    end

    assert_match /Failed to import repository/, error.message
  end

  # ============================================================================
  # Stage 4: Blob Transfer Errors (Most Complex)
  # ============================================================================

  test "list_blobs raises RateLimitError on HTTP 429" do
    stub_http_get_with_code(
      "#{@migration.old_pds_host}/xrpc/com.atproto.sync.listBlobs?did=#{@migration.did}",
      429,
      { error: 'RateLimitExceeded' }.to_json
    )

    error = assert_raises(GoatService::RateLimitError) do
      @service.list_blobs
    end

    assert_match /rate limit exceeded/, error.message
  end

  test "list_blobs raises NetworkError on non-success response" do
    stub_http_get_with_code(
      "#{@migration.old_pds_host}/xrpc/com.atproto.sync.listBlobs?did=#{@migration.did}",
      500,
      { error: 'InternalServerError' }.to_json
    )

    error = assert_raises(GoatService::NetworkError) do
      @service.list_blobs
    end

    assert_match /Failed to list blobs/, error.message
  end

  test "list_blobs includes cursor parameter when provided" do
    cursor = "next_page_cursor"
    stub_http_get(
      "#{@migration.old_pds_host}/xrpc/com.atproto.sync.listBlobs?did=#{@migration.did}&cursor=#{cursor}",
      { cids: [], cursor: nil }.to_json
    )

    result = @service.list_blobs(cursor)

    assert_equal [], result['cids']
  end

  test "download_blob raises RateLimitError on HTTP 429" do
    cid = "bafybeiabc123"
    stub_http_get_with_code(
      "#{@migration.old_pds_host}/xrpc/com.atproto.sync.getBlob?did=#{@migration.did}&cid=#{cid}",
      429,
      ""
    )

    error = assert_raises(GoatService::RateLimitError) do
      @service.download_blob(cid)
    end

    assert_match /rate limit exceeded/, error.message
  end

  test "download_blob raises NetworkError on 404 (blob not found)" do
    cid = "bafybeimissing"
    stub_http_get_with_code(
      "#{@migration.old_pds_host}/xrpc/com.atproto.sync.getBlob?did=#{@migration.did}&cid=#{cid}",
      404,
      { error: 'BlobNotFound' }.to_json
    )

    error = assert_raises(GoatService::NetworkError) do
      @service.download_blob(cid)
    end

    assert_match /Failed to download blob/, error.message
  end

  test "upload_blob raises RateLimitError on HTTP 429" do
    blob_path = @service.work_dir.join('blobs', 'test_blob')
    FileUtils.mkdir_p(blob_path.dirname)
    File.binwrite(blob_path, 'test blob data')

    # Stub session token retrieval
    allow_session_token_retrieval

    stub_http_post_with_code(
      "#{@migration.new_pds_host}/xrpc/com.atproto.repo.uploadBlob",
      429,
      { error: 'RateLimitExceeded' }.to_json
    )

    error = assert_raises(GoatService::RateLimitError) do
      @service.upload_blob(blob_path.to_s)
    end

    assert_match /rate limit exceeded/, error.message
  end

  test "upload_blob refreshes token and retries on 401" do
    blob_path = @service.work_dir.join('blobs', 'test_blob')
    FileUtils.mkdir_p(blob_path.dirname)
    File.binwrite(blob_path, 'test blob data')

    # First call returns 401 (expired token)
    # Second call (after refresh) succeeds
    call_count = 0
    stub_http_post_dynamic(
      "#{@migration.new_pds_host}/xrpc/com.atproto.repo.uploadBlob"
    ) do
      call_count += 1
      if call_count == 1
        [401, { error: 'ExpiredToken' }.to_json]
      else
        [200, { blob: { ref: { '$link' => 'bafybeiabc123' } } }.to_json]
      end
    end

    # Stub session creation
    allow_session_token_retrieval
    stub_session_creation

    result = @service.upload_blob(blob_path.to_s)

    assert result['blob']['ref']['$link'].present?
    assert_equal 2, call_count # Should have made 2 attempts
  end

  test "upload_blob raises GoatError when blob file not found" do
    error = assert_raises(GoatService::GoatError) do
      @service.upload_blob('/nonexistent/blob')
    end

    assert_match /Blob file not found/, error.message
  end

  # ============================================================================
  # Stage 5: Preferences Import/Export Errors
  # ============================================================================

  test "export_preferences raises GoatError on failure" do
    stub_goat_command_success(['account', 'login'], "", "")
    stub_goat_command_failure(
      ['bsky', 'prefs', 'export'],
      "failed to export preferences"
    )

    error = assert_raises(GoatService::GoatError) do
      @service.export_preferences
    end

    assert_match /Failed to export preferences/, error.message
  end

  test "import_preferences raises GoatError when prefs file not found" do
    error = assert_raises(GoatService::GoatError) do
      @service.import_preferences('/nonexistent/prefs.json')
    end

    assert_match /Preferences file not found/, error.message
  end

  test "import_preferences raises GoatError on import failure" do
    prefs_path = @service.work_dir.join('prefs.json')
    File.write(prefs_path, '{}')

    stub_goat_command_success(['account', 'login'], "", "")
    stub_goat_command_failure(
      ['bsky', 'prefs', 'import', prefs_path.to_s],
      "invalid preferences format"
    )

    error = assert_raises(GoatService::GoatError) do
      @service.import_preferences(prefs_path.to_s)
    end

    assert_match /Failed to import preferences/, error.message
  end

  # ============================================================================
  # Stage 6: PLC Token Errors
  # ============================================================================

  test "request_plc_token raises GoatError on failure" do
    stub_goat_command_success(['account', 'login'], "", "")
    stub_goat_command_failure(
      ['account', 'plc', 'request-token'],
      "PLC token request denied"
    )

    error = assert_raises(GoatService::GoatError) do
      @service.request_plc_token
    end

    assert_match /Failed to request PLC token/, error.message
  end

  # ============================================================================
  # Stage 7: PLC Operation Errors (CRITICAL)
  # ============================================================================

  test "get_recommended_plc_operation raises GoatError on failure" do
    stub_goat_command_success(['account', 'login'], "", "")
    stub_goat_command_failure(
      ['account', 'plc', 'recommended'],
      "failed to get recommended parameters"
    )

    error = assert_raises(GoatService::GoatError) do
      @service.get_recommended_plc_operation
    end

    assert_match /Failed to get recommended PLC operation/, error.message
  end

  test "sign_plc_operation raises GoatError when unsigned file not found" do
    error = assert_raises(GoatService::GoatError) do
      @service.sign_plc_operation('/nonexistent/unsigned.json', 'token123')
    end

    assert_match /Unsigned PLC operation file not found/, error.message
  end

  test "sign_plc_operation raises GoatError when token is nil" do
    unsigned_path = @service.work_dir.join('plc_unsigned.json')
    File.write(unsigned_path, '{}')

    error = assert_raises(GoatService::GoatError) do
      @service.sign_plc_operation(unsigned_path.to_s, nil)
    end

    assert_match /PLC token is required/, error.message
  end

  test "sign_plc_operation raises GoatError when token is empty" do
    unsigned_path = @service.work_dir.join('plc_unsigned.json')
    File.write(unsigned_path, '{}')

    error = assert_raises(GoatService::GoatError) do
      @service.sign_plc_operation(unsigned_path.to_s, "")
    end

    assert_match /PLC token is required/, error.message
  end

  test "sign_plc_operation raises GoatError on signing failure" do
    unsigned_path = @service.work_dir.join('plc_unsigned.json')
    File.write(unsigned_path, '{}')

    stub_goat_command_success(['account', 'login'], "", "")
    stub_goat_command_failure(
      ['account', 'plc', 'sign', '--token', 'invalid-token', unsigned_path.to_s],
      "invalid PLC token"
    )

    error = assert_raises(GoatService::GoatError) do
      @service.sign_plc_operation(unsigned_path.to_s, 'invalid-token')
    end

    assert_match /Failed to sign PLC operation/, error.message
  end

  test "submit_plc_operation raises GoatError when signed file not found" do
    error = assert_raises(GoatService::GoatError) do
      @service.submit_plc_operation('/nonexistent/signed.json')
    end

    assert_match /Signed PLC operation file not found/, error.message
  end

  test "submit_plc_operation raises GoatError on submission failure" do
    signed_path = @service.work_dir.join('plc_signed.json')
    File.write(signed_path, '{}')

    stub_goat_command_success(['account', 'login'], "", "")
    stub_goat_command_failure(
      ['account', 'plc', 'submit', signed_path.to_s],
      "PLC directory rejected operation"
    )

    error = assert_raises(GoatService::GoatError) do
      @service.submit_plc_operation(signed_path.to_s)
    end

    assert_match /Failed to submit PLC operation/, error.message
  end

  # ============================================================================
  # Stage 8: Account Activation/Deactivation Errors
  # ============================================================================

  test "activate_account raises GoatError on failure" do
    stub_goat_command_success(['account', 'login'], "", "")
    stub_goat_command_failure(
      ['account', 'activate'],
      "activation failed"
    )

    error = assert_raises(GoatService::GoatError) do
      @service.activate_account
    end

    assert_match /Failed to activate account/, error.message
  end

  test "deactivate_account raises GoatError on failure" do
    stub_goat_command_success(['account', 'login'], "", "")
    stub_goat_command_failure(
      ['account', 'deactivate'],
      "deactivation failed"
    )

    error = assert_raises(GoatService::GoatError) do
      @service.deactivate_account
    end

    assert_match /Failed to deactivate account/, error.message
  end

  # ============================================================================
  # Rotation Key Errors
  # ============================================================================

  test "generate_rotation_key raises GoatError on parsing failure" do
    stub_goat_command_success(
      ['key', 'generate', '--type', 'P-256'],
      "unexpected output format",
      ""
    )

    error = assert_raises(GoatService::GoatError) do
      @service.generate_rotation_key
    end

    assert_match /Failed to parse rotation key/, error.message
  end

  test "generate_rotation_key raises GoatError when command fails" do
    stub_goat_command_failure(
      ['key', 'generate', '--type', 'P-256'],
      "key generation failed"
    )

    error = assert_raises(GoatService::GoatError) do
      @service.generate_rotation_key
    end

    assert_match /Failed to generate rotation key/, error.message
  end

  test "add_rotation_key_to_pds raises GoatError on failure" do
    stub_goat_command_failure(
      ['account', 'plc', 'add-rotation-key'],
      "failed to add rotation key"
    )

    error = assert_raises(GoatService::GoatError) do
      @service.add_rotation_key_to_pds('did:key:test')
    end

    assert_match /Failed to add rotation key/, error.message
  end

  # ============================================================================
  # Network & Timeout Errors
  # ============================================================================

  test "execute_command raises TimeoutError when command exceeds timeout" do
    stub_command_timeout(['sleep', '10'], timeout: 1)

    error = assert_raises(GoatService::TimeoutError) do
      @service.send(:execute_command, 'sleep', '10', timeout: 1)
    end

    assert_match /Command timed out after 1 seconds/, error.message
  end

  test "execute_goat masks passwords in logs" do
    # Capture logger output
    log_output = StringIO.new
    original_logger = @service.logger
    @service.instance_variable_set(:@logger, Logger.new(log_output))

    stub_goat_command_success(
      ['account', 'login', '--pds-host', 'https://test.com',
       '-u', 'user', '-p', 'secret_password'],
      "", ""
    )

    @service.send(:execute_goat, 'account', 'login', '--pds-host', 'https://test.com',
                  '-u', 'user', '-p', 'secret_password')

    log_contents = log_output.string
    assert_not log_contents.include?('secret_password'),
      "Password should be masked in logs"
    assert log_contents.include?('[REDACTED]'),
      "Should show [REDACTED] for masked values"
  ensure
    @service.instance_variable_set(:@logger, original_logger)
  end

  test "execute_goat masks tokens in logs" do
    log_output = StringIO.new
    original_logger = @service.logger
    @service.instance_variable_set(:@logger, Logger.new(log_output))

    stub_goat_command_success(
      ['account', 'plc', 'sign', '--token', 'secret_plc_token', 'file.json'],
      "", ""
    )

    @service.send(:execute_goat, 'account', 'plc', 'sign',
                  '--token', 'secret_plc_token', 'file.json')

    log_contents = log_output.string
    assert_not log_contents.include?('secret_plc_token'),
      "Token should be masked in logs"
  ensure
    @service.instance_variable_set(:@logger, original_logger)
  end

  # ============================================================================
  # DID/Handle Resolution Errors
  # ============================================================================

  test "resolve_handle_to_did raises NetworkError when handle not found" do
    stub_dns_lookup_failure('_atproto.nonexistent.handle.com')
    stub_http_get_with_code('https://bsky.social/xrpc/com.atproto.identity.resolveHandle?handle=nonexistent.handle.com', 404, "")
    stub_http_get_with_code('https://bsky.network/xrpc/com.atproto.identity.resolveHandle?handle=nonexistent.handle.com', 404, "")

    error = assert_raises(GoatService::NetworkError) do
      GoatService.resolve_handle_to_did('nonexistent.handle.com')
    end

    assert_match /Could not resolve handle/, error.message
  end

  test "resolve_did_to_pds raises NetworkError when DID document not found" do
    stub_http_get_with_code(
      "https://plc.directory/did:plc:nonexistent",
      404,
      { error: 'NotFound' }.to_json
    )

    error = assert_raises(GoatService::NetworkError) do
      GoatService.resolve_did_to_pds('did:plc:nonexistent')
    end

    assert_match /Failed to fetch DID document/, error.message
  end

  test "resolve_did_to_pds raises GoatError when no PDS endpoint in DID document" do
    stub_http_get(
      "https://plc.directory/did:plc:test",
      { did: 'did:plc:test', service: [] }.to_json
    )

    error = assert_raises(GoatService::GoatError) do
      GoatService.resolve_did_to_pds('did:plc:test')
    end

    assert_match /No PDS endpoint found/, error.message
  end

  # ============================================================================
  # Helper Methods
  # ============================================================================

  private

  def stub_goat_command_success(args, stdout, stderr)
    # Stub Open3.capture3 for goat commands
    Open3.stubs(:capture3).with(
      has_entries('ATP_PLC_HOST' => anything, 'ATP_PDS_HOST' => anything),
      'goat',
      *args,
      chdir: @service.work_dir
    ).returns([stdout, stderr, stub(success?: true)])
  end

  def stub_goat_command_failure(args, error_message)
    Open3.stubs(:capture3).with(
      has_entries('ATP_PLC_HOST' => anything, 'ATP_PDS_HOST' => anything),
      'goat',
      *args.any?,
      chdir: @service.work_dir
    ).returns(["", error_message, stub(success?: false)])
  end

  def stub_command_success(cmd, stdout, stderr, &block)
    Open3.stubs(:capture3).with({}, *cmd, chdir: @service.work_dir).returns([stdout, stderr, stub(success?: true)])
    block.call if block_given?
  end

  def stub_command_timeout(cmd, timeout:)
    Open3.stubs(:capture3).with({}, *cmd.any?, chdir: @service.work_dir).raises(Timeout::Error)
  end

  def stub_http_get(url, response_body, code: 200)
    HTTParty.stubs(:get).with(url, any_parameters).returns(
      stub(success?: code == 200, code: code, body: response_body)
    )
  end

  def stub_http_get_with_code(url, code, response_body)
    HTTParty.stubs(:get).with(has_entries(anything), anything).returns(
      stub(success?: code == 200, code: code, body: response_body, message: "HTTP #{code}")
    )
  end

  def stub_http_post_with_code(url, code, response_body)
    HTTParty.stubs(:post).with(url, any_parameters).returns(
      stub(success?: code == 200, code: code, body: response_body, message: "HTTP #{code}")
    )
  end

  def stub_http_post_dynamic(url, &block)
    HTTParty.stubs(:post).with(url, any_parameters).returns do
      code, body = block.call
      stub(success?: code == 200, code: code, body: body, message: "HTTP #{code}")
    end
  end

  def stub_dns_lookup_failure(record)
    Resolv::DNS.any_instance.stubs(:getresources).with(record, Resolv::DNS::Resource::IN::TXT).returns([])
  end

  def allow_session_token_retrieval
    @service.instance_variable_get(:@access_tokens)["#{@migration.new_pds_host}:#{@migration.did}"] = 'test-token'
  end

  def stub_session_creation
    HTTParty.stubs(:post).with(
      "#{@migration.new_pds_host}/xrpc/com.atproto.server.createSession",
      any_parameters
    ).returns(
      stub(success?: true, code: 200, body: { accessJwt: 'new-token' }.to_json)
    )
  end
end
