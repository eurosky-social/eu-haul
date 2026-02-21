require "test_helper"
require "webmock/minitest"

# GoatService Rate Limit Retry Tests
# Tests for the with_rate_limit_retry exponential backoff mechanism in GoatService.
# The private method retries up to MAX_RATE_LIMIT_RETRIES (4) times on RateLimitError,
# using Retry-After header when available or exponential backoff with jitter.
class RateLimitRetryTest < ActiveSupport::TestCase
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
  # Basic retry logic (tested via send to private method)
  # ============================================================================

  test "succeeds on first try without retry" do
    @service.stubs(:sleep)

    result = @service.send(:with_rate_limit_retry, 'test') do
      "success"
    end

    assert_equal "success", result
  end

  test "retries on RateLimitError and succeeds" do
    @service.stubs(:sleep)

    call_count = 0
    result = @service.send(:with_rate_limit_retry, 'test') do
      call_count += 1
      raise GoatService::RateLimitError, "rate limited" if call_count == 1
      "success_after_retry"
    end

    assert_equal "success_after_retry", result
    assert_equal 2, call_count
  end

  test "uses Retry-After header when available" do
    sleep_values = []
    @service.stubs(:sleep).with { |val| sleep_values << val; true }

    call_count = 0
    @service.send(:with_rate_limit_retry, 'test') do
      call_count += 1
      raise GoatService::RateLimitError.new("rate limited", retry_after: 5) if call_count == 1
      "success"
    end

    assert_equal 1, sleep_values.length
    # Should be approximately 5 seconds plus up to 25% jitter (5 + 0..1.25)
    assert_operator sleep_values.first, :>=, 5.0
    assert_operator sleep_values.first, :<=, 6.25
  end

  test "gives up after max retries" do
    @service.stubs(:sleep)

    call_count = 0
    error = assert_raises(GoatService::RateLimitError) do
      @service.send(:with_rate_limit_retry, 'test') do
        call_count += 1
        raise GoatService::RateLimitError, "rate limited"
      end
    end

    # MAX_RATE_LIMIT_RETRIES is 4, so 1 initial + 4 retries = 5 total calls
    assert_equal 5, call_count
    assert_match /rate limited/, error.message
  end

  test "does not retry non-rate-limit errors" do
    @service.stubs(:sleep)

    call_count = 0
    error = assert_raises(GoatService::NetworkError) do
      @service.send(:with_rate_limit_retry, 'test') do
        call_count += 1
        raise GoatService::NetworkError, "connection refused"
      end
    end

    assert_equal 1, call_count
    assert_match /connection refused/, error.message
  end

  # ============================================================================
  # Public methods that use with_rate_limit_retry
  # ============================================================================

  test "list_blobs retries on rate limit" do
    @service.stubs(:sleep)

    # First request returns 429, second returns 200
    stub_request(:get, "#{@migration.old_pds_host}/xrpc/com.atproto.sync.listBlobs")
      .with(query: { did: @migration.did })
      .to_return(
        { status: 429, body: { error: 'RateLimitExceeded' }.to_json, headers: { 'Retry-After' => '2' } },
        { status: 200, body: { cids: ['bafyabc123'], cursor: nil }.to_json, headers: { 'Content-Type' => 'application/json' } }
      )

    result = @service.list_blobs

    assert_equal ['bafyabc123'], result['cids']
  end

  test "download_blob retries on rate limit" do
    @service.stubs(:sleep)

    cid = "bafybeiabc123"

    # First request returns 429, second returns blob data
    stub_request(:get, "#{@migration.old_pds_host}/xrpc/com.atproto.sync.getBlob")
      .with(query: { did: @migration.did, cid: cid })
      .to_return(
        { status: 429, body: "", headers: { 'Retry-After' => '1' } },
        { status: 200, body: "blob-binary-data", headers: { 'Content-Type' => 'application/octet-stream' } }
      )

    blob_path = @service.download_blob(cid)

    assert File.exist?(blob_path)
    assert_equal "blob-binary-data", File.binread(blob_path)
  ensure
    FileUtils.rm_rf(@service.work_dir.join("blobs")) if @service
  end

  test "upload_blob retries on rate limit" do
    @service.stubs(:sleep)

    blob_path = @service.work_dir.join('blobs', 'test_upload_blob')
    FileUtils.mkdir_p(blob_path.dirname)
    File.binwrite(blob_path, 'test blob data for upload')

    # Pre-populate access token to avoid login
    @service.instance_variable_get(:@access_tokens)["#{@migration.new_pds_host}:#{@migration.did}"] = 'test-token'

    # First request returns 429, second returns success
    stub_request(:post, "#{@migration.new_pds_host}/xrpc/com.atproto.repo.uploadBlob")
      .to_return(
        { status: 429, body: { error: 'RateLimitExceeded' }.to_json, headers: { 'Retry-After' => '1' } },
        { status: 200, body: { blob: { ref: { '$link' => 'bafyuploaded' } } }.to_json, headers: { 'Content-Type' => 'application/json' } }
      )

    result = @service.upload_blob(blob_path.to_s)

    assert_equal 'bafyuploaded', result['blob']['ref']['$link']
  ensure
    FileUtils.rm_rf(blob_path.dirname) if blob_path
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
