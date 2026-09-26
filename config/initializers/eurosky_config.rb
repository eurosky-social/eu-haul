# frozen_string_literal: true

# EuroskyConfig - Configuration for deployment modes and UI customization
#
# This module provides centralized configuration for the Eurosky Migration tool.
# All configuration is loaded from environment variables with sensible defaults.
#
# Deployment Modes:
#   - standalone: Users enter their target PDS URL (default)
#   - bound: Target PDS is pre-configured, users cannot change it
#
# UI Customization:
#   - Site name, subtitle, colors, logos are all configurable
#   - Falls back to default Eurosky branding
#
# Invite Codes:
#   - Can be required, optional, or hidden via ENV configuration

module EuroskyConfig
  # Deployment mode configuration
  DEPLOYMENT_MODE = ENV.fetch('DEPLOYMENT_MODE', 'standalone').downcase.freeze
  TARGET_PDS_HOST = ENV['TARGET_PDS_HOST']&.freeze

  # Invite code configuration
  INVITE_CODE_MODE = ENV.fetch('INVITE_CODE_MODE', 'optional').downcase.freeze

  # UI Branding
  SITE_NAME = ENV.fetch('SITE_NAME', 'Eurosky Migration').freeze
  SITE_SUBTITLE = ENV.fetch('SITE_SUBTITLE', 'Migrate your AT Protocol account to a new PDS').freeze
  PRIMARY_COLOR = ENV.fetch('PRIMARY_COLOR', '#667eea').freeze
  SECONDARY_COLOR = ENV.fetch('SECONDARY_COLOR', '#764ba2').freeze
  LOGO_URL = ENV['LOGO_URL']&.freeze
  FAVICON_URL = ENV['FAVICON_URL']&.freeze
  BACKGROUND_IMAGE_URL = ENV['BACKGROUND_IMAGE_URL']&.freeze

  # PDS Configuration
  DEFAULT_TARGET_PDS = ENV['DEFAULT_TARGET_PDS']&.freeze

  # Destination servers offered in the wizard's server dropdown. A "Custom
  # Server..." entry is always appended after them. Override with
  # TARGET_PDS_OPTIONS, a JSON array of {"label": ..., "url": ...} objects.
  # Labels are shown as-is in every locale.
  DEFAULT_TARGET_PDS_OPTIONS = [
    { label: 'Eurosky (eurosky.social)', url: 'https://eurosky.social' },
    { label: 'Blacksky (blacksky.app)', url: 'https://blacksky.app' },
    { label: 'myatproto (myatproto.social)', url: 'https://myatproto.social' },
    { label: 'Bluesky (bsky.social)', url: 'https://bsky.social' }
  ].map(&:freeze).freeze

  # Handle domains a PDS hands out to its users (user.bsky.social). A source
  # handle ending in one of these is PDS-owned and can't be kept, even though
  # the PDS answers its DNS/well-known lookups. GoatService.handle_matches_source_pds?
  # also asks the source PDS for its own list (describeServer availableUserDomains),
  # so this list is the no-network fast path and the fallback when that PDS
  # can't be asked. PDS_HOSTED_HANDLE_SUFFIXES (comma-separated, .oso.social)
  # adds to it.
  DEFAULT_PDS_HOSTED_HANDLE_SUFFIXES = %w[
    .bsky.social
    .blacksky.app
    .staging.bsky.dev
    .test.bsky.network
  ].map(&:freeze).freeze

  # Legal URLs
  # If set to an external URL (e.g. https://...), those are used directly.
  # If not set, defaults to internal routes that render ERB templates with ENV values.
  PRIVACY_POLICY_URL = ENV.fetch('PRIVACY_POLICY_URL', '/privacy-policy').freeze
  TERMS_OF_SERVICE_URL = ENV.fetch('TERMS_OF_SERVICE_URL', '/terms-of-service').freeze

  # Legal page content (used by internal ERB templates at /privacy-policy and /terms-of-service)
  OPERATOR_NAME = ENV.fetch('OPERATOR_NAME', 'UNCONFIGURED').freeze
  OPERATOR_EMAIL = ENV.fetch('OPERATOR_EMAIL') { ENV.fetch('SUPPORT_EMAIL', 'support@example.com') }.freeze
  OPERATOR_ADDRESS = ENV['OPERATOR_ADDRESS']&.freeze
  EFFECTIVE_DATE = ENV.fetch('EFFECTIVE_DATE', 'UNCONFIGURED').freeze
  GOVERNING_JURISDICTION = ENV.fetch('GOVERNING_JURISDICTION', 'UNCONFIGURED').freeze
  LIABILITY_CAP = ENV.fetch('LIABILITY_CAP', 'EUR 0 (this is a free service)').freeze
  LOG_RETENTION_DAYS = ENV.fetch('LOG_RETENTION_DAYS', '30').freeze
  REPO_URL = ENV.fetch('REPO_URL', 'https://github.com/eurosky-social/u-haul').freeze

  # Hosting provider details (used in the privacy policy infrastructure section).
  # Leave unset if you prefer to point PRIVACY_POLICY_URL to an external document instead.
  # HOSTING_PROVIDER_NAME       – Legal name of the infrastructure/hosting provider.
  # HOSTING_PROVIDER_ADDRESS    – Full postal address of the hosting provider.
  # HOSTING_PROVIDER_DATA_LOCATION – Human-readable data location, e.g. "European Union / EEA".
  # HOSTING_PROVIDER_TOM_URL    – URL to the provider's Technical and Organizational Measures doc.
  # HOSTING_PROVIDER_CERTIFICATIONS – Comma-separated list of certifications, e.g. "ISO 27001, BSI C5".
  # HOSTING_PROVIDER_SUBPROCESSORS_URL – URL to the provider's sub-processor / DPA page.
  HOSTING_PROVIDER_NAME = ENV['HOSTING_PROVIDER_NAME']&.freeze
  HOSTING_PROVIDER_ADDRESS = ENV['HOSTING_PROVIDER_ADDRESS']&.freeze
  HOSTING_PROVIDER_DATA_LOCATION = ENV.fetch('HOSTING_PROVIDER_DATA_LOCATION', 'European Union / EEA').freeze
  HOSTING_PROVIDER_TOM_URL = ENV['HOSTING_PROVIDER_TOM_URL']&.freeze
  HOSTING_PROVIDER_CERTIFICATIONS = ENV['HOSTING_PROVIDER_CERTIFICATIONS']&.freeze
  HOSTING_PROVIDER_SUBPROCESSORS_URL = ENV['HOSTING_PROVIDER_SUBPROCESSORS_URL']&.freeze

  # Validation
  class ConfigurationError < StandardError; end

  # Valid deployment modes
  VALID_DEPLOYMENT_MODES = %w[standalone bound].freeze

  # Valid invite code modes
  VALID_INVITE_CODE_MODES = %w[required optional hidden].freeze

  # Validate configuration on load
  def self.validate!
    # Validate deployment mode
    unless VALID_DEPLOYMENT_MODES.include?(DEPLOYMENT_MODE)
      raise ConfigurationError,
            "Invalid DEPLOYMENT_MODE: #{DEPLOYMENT_MODE}. Must be one of: #{VALID_DEPLOYMENT_MODES.join(', ')}"
    end

    # Validate bound mode requires TARGET_PDS_HOST
    if DEPLOYMENT_MODE == 'bound' && TARGET_PDS_HOST.blank?
      raise ConfigurationError,
            "DEPLOYMENT_MODE=bound requires TARGET_PDS_HOST to be set"
    end

    # Validate invite code mode
    unless VALID_INVITE_CODE_MODES.include?(INVITE_CODE_MODE)
      raise ConfigurationError,
            "Invalid INVITE_CODE_MODE: #{INVITE_CODE_MODE}. Must be one of: #{VALID_INVITE_CODE_MODES.join(', ')}"
    end

    # Validate color hex codes
    validate_color!(PRIMARY_COLOR, 'PRIMARY_COLOR')
    validate_color!(SECONDARY_COLOR, 'SECONDARY_COLOR')

    # Parse the lists now so a bad TARGET_PDS_OPTIONS or
    # PDS_HOSTED_HANDLE_SUFFIXES fails the boot
    pds_hosted_handle_suffixes
    options = target_pds_options
    if DEFAULT_TARGET_PDS.present? && options.none? { |o| o[:url] == DEFAULT_TARGET_PDS }
      Rails.logger.warn("DEFAULT_TARGET_PDS #{DEFAULT_TARGET_PDS} is not in the destination list; nothing will be pre-selected")
    end

    Rails.logger.info("EuroskyConfig loaded: mode=#{DEPLOYMENT_MODE}, invite_codes=#{INVITE_CODE_MODE}")
  end

  # Helper methods
  def self.standalone_mode?
    DEPLOYMENT_MODE == 'standalone'
  end

  def self.bound_mode?
    DEPLOYMENT_MODE == 'bound'
  end

  def self.invite_code_required?
    INVITE_CODE_MODE == 'required'
  end

  def self.invite_code_optional?
    INVITE_CODE_MODE == 'optional'
  end

  def self.invite_code_hidden?
    INVITE_CODE_MODE == 'hidden'
  end

  def self.invite_code_enabled?
    !invite_code_hidden?
  end

  # Destination servers for the wizard dropdown: TARGET_PDS_OPTIONS if set,
  # otherwise DEFAULT_TARGET_PDS_OPTIONS.
  def self.target_pds_options
    @target_pds_options ||= parse_target_pds_options(ENV['TARGET_PDS_OPTIONS'])
  end

  # Parse a TARGET_PDS_OPTIONS value into [{label:, url:}, ...]. Blank means the
  # built-in default list.
  def self.parse_target_pds_options(raw)
    return DEFAULT_TARGET_PDS_OPTIONS if raw.blank?

    entries = begin
      JSON.parse(raw)
    rescue JSON::ParserError => e
      raise ConfigurationError, "TARGET_PDS_OPTIONS is not valid JSON: #{e.message}"
    end

    unless entries.is_a?(Array)
      raise ConfigurationError, 'TARGET_PDS_OPTIONS must be a JSON array of {"label": ..., "url": ...} objects'
    end

    entries.each_with_index.map do |entry, i|
      label = entry['label'] if entry.is_a?(Hash)
      url = entry['url'] if entry.is_a?(Hash)

      unless label.is_a?(String) && label.present? && url.is_a?(String) && url.match?(%r{\Ahttps?://[^/\s]+/?\z})
        raise ConfigurationError,
              "TARGET_PDS_OPTIONS entry #{i} must have a non-empty \"label\" and a \"url\" like https://pds.example.com, got: #{entry.inspect}"
      end

      { label: label.strip, url: url.chomp('/') }.freeze
    end.freeze
  end

  # Handle suffixes treated as PDS-owned: DEFAULT_PDS_HOSTED_HANDLE_SUFFIXES
  # plus PDS_HOSTED_HANDLE_SUFFIXES.
  def self.pds_hosted_handle_suffixes
    @pds_hosted_handle_suffixes ||= parse_pds_hosted_handle_suffixes(ENV['PDS_HOSTED_HANDLE_SUFFIXES'])
  end

  # Parse a comma-separated PDS_HOSTED_HANDLE_SUFFIXES value and add it to the
  # built-in list. Adding rather than replacing means setting only .oso.social
  # can't silently drop .bsky.social, which would offer every bsky.social user
  # to keep a handle they don't own.
  def self.parse_pds_hosted_handle_suffixes(raw)
    return DEFAULT_PDS_HOSTED_HANDLE_SUFFIXES if raw.blank?

    configured = raw.split(',').map(&:strip).reject(&:empty?).map do |entry|
      normalize_handle_suffix(entry) ||
        raise(ConfigurationError, "PDS_HOSTED_HANDLE_SUFFIXES entry #{entry.inspect} must be a domain like .pds.example.com")
    end

    (DEFAULT_PDS_HOSTED_HANDLE_SUFFIXES + configured).uniq.freeze
  end

  # Lowercase a handle domain and give it a leading dot (OSO.social ->
  # .oso.social). Nil unless it is a domain of at least two labels: a bare
  # .social would claim every handle on that TLD.
  def self.normalize_handle_suffix(entry)
    suffix = entry.to_s.strip.downcase
    suffix = ".#{suffix}" unless suffix.start_with?('.')
    return nil unless suffix.match?(/\A(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?){2,}\z/)

    suffix.freeze
  end

  # Get CSS gradient string for backgrounds
  def self.gradient_css
    "linear-gradient(135deg, #{PRIMARY_COLOR} 0%, #{SECONDARY_COLOR} 100%)"
  end

  private

  # Validate color format (supports #hex, rgb(), rgba(), hsl(), hsla(), and named colors)
  def self.validate_color!(color, name)
    return if color.blank?

    # Allow hex colors (#fff, #ffffff)
    return if color.match?(/\A#([0-9a-f]{3}|[0-9a-f]{6})\z/i)

    # Allow rgb/rgba
    return if color.match?(/\Argba?\([^)]+\)\z/i)

    # Allow hsl/hsla
    return if color.match?(/\Ahsla?\([^)]+\)\z/i)

    # Allow CSS named colors (basic set)
    named_colors = %w[
      black white red green blue yellow cyan magenta
      gray grey silver maroon navy purple teal olive
      lime aqua fuchsia transparent
    ]
    return if named_colors.include?(color.downcase)

    raise ConfigurationError,
          "Invalid color format for #{name}: #{color}. Use #hex, rgb(), rgba(), hsl(), hsla(), or named color."
  end
end

# Validate configuration on initialization
EuroskyConfig.validate!
