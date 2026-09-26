require "test_helper"

class EuroskyConfigTest < ActiveSupport::TestCase
  test "blank TARGET_PDS_OPTIONS falls back to the built-in destinations" do
    assert_equal EuroskyConfig::DEFAULT_TARGET_PDS_OPTIONS, EuroskyConfig.parse_target_pds_options(nil)
    assert_equal EuroskyConfig::DEFAULT_TARGET_PDS_OPTIONS, EuroskyConfig.parse_target_pds_options("  ")
    assert_equal %w[https://eurosky.social https://blacksky.app https://myatproto.social https://bsky.social],
                 EuroskyConfig::DEFAULT_TARGET_PDS_OPTIONS.map { |o| o[:url] }
  end

  test "parses a JSON destination list in order" do
    options = EuroskyConfig.parse_target_pds_options(<<~JSON)
      [{"label": "Eurosky (eurosky.social)", "url": "https://eurosky.social"},
       {"label": " oso (oso.social) ", "url": "https://pds.oso.social/"}]
    JSON

    assert_equal [
      { label: "Eurosky (eurosky.social)", url: "https://eurosky.social" },
      { label: "oso (oso.social)", url: "https://pds.oso.social" }
    ], options
  end

  test "an empty array leaves only the custom entry" do
    assert_equal [], EuroskyConfig.parse_target_pds_options("[]")
  end

  test "rejects invalid JSON" do
    error = assert_raises(EuroskyConfig::ConfigurationError) do
      EuroskyConfig.parse_target_pds_options("[{label: nope}]")
    end
    assert_match(/not valid JSON/, error.message)
  end

  test "rejects a non-array" do
    assert_raises(EuroskyConfig::ConfigurationError) do
      EuroskyConfig.parse_target_pds_options('{"label": "x", "url": "https://x.example"}')
    end
  end

  test "rejects entries without a label or a bare server URL" do
    [
      '[{"url": "https://pds.example.com"}]',
      '[{"label": "", "url": "https://pds.example.com"}]',
      '[{"label": "x"}]',
      '[{"label": "x", "url": "pds.example.com"}]',
      '[{"label": "x", "url": "https://pds.example.com/xrpc"}]',
      '["https://pds.example.com"]'
    ].each do |raw|
      assert_raises(EuroskyConfig::ConfigurationError, raw) { EuroskyConfig.parse_target_pds_options(raw) }
    end
  end
end

class EuroskyConfigHandleSuffixesTest < ActiveSupport::TestCase
  test "blank PDS_HOSTED_HANDLE_SUFFIXES falls back to the built-in suffixes" do
    assert_equal %w[.bsky.social .blacksky.app .staging.bsky.dev .test.bsky.network],
                 EuroskyConfig.parse_pds_hosted_handle_suffixes(nil)
    assert_equal EuroskyConfig::DEFAULT_PDS_HOSTED_HANDLE_SUFFIXES, EuroskyConfig.parse_pds_hosted_handle_suffixes(" ")
  end

  test "configured suffixes are added to the built-in ones, never replace them" do
    assert_equal %w[.bsky.social .blacksky.app .staging.bsky.dev .test.bsky.network .oso.social],
                 EuroskyConfig.parse_pds_hosted_handle_suffixes(".oso.social")
  end

  test "normalizes case, whitespace, the leading dot and duplicates" do
    assert_equal EuroskyConfig::DEFAULT_PDS_HOSTED_HANDLE_SUFFIXES + %w[.oso.social],
                 EuroskyConfig.parse_pds_hosted_handle_suffixes(" .bsky.social, OSO.social ,,.oso.social")
  end

  test "normalize_handle_suffix returns nil for anything that isn't a two-label domain" do
    assert_equal ".mu.social", EuroskyConfig.normalize_handle_suffix(" MU.social ")
    assert_equal ".oso.social", EuroskyConfig.normalize_handle_suffix(".oso.social")
    [".social", "", nil, "oso social", "https://oso.social"].each do |raw|
      assert_nil EuroskyConfig.normalize_handle_suffix(raw), raw.inspect
    end
  end

  test "rejects a bare TLD or a non-domain" do
    [".social", "social", "oso social", ".oso..social", "https://oso.social"].each do |raw|
      assert_raises(EuroskyConfig::ConfigurationError, raw) { EuroskyConfig.parse_pds_hosted_handle_suffixes(raw) }
    end
  end
end
