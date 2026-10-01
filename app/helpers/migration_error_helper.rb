# MigrationErrorHelper - User-friendly error messages and recovery guidance
#
# Transforms technical error messages into actionable, user-friendly explanations
# with context, next steps, and recovery options.
#
# Every user-facing string lives in config/locales/*.yml under
# migrations.error_messages.<type>.*; only the raw error message
# (technical_details) is shown verbatim.
#
# Usage:
#   error_context = MigrationErrorHelper.explain_error(migration)
#   => {
#        severity: :warning | :error | :critical,
#        title: "Network connection error",
#        what_happened: "The connection to your old PDS timed out...",
#        current_status: "Retrying automatically (attempt 2 of 3)",
#        what_to_do: ["Wait for the automatic retry (recommended)", ...],
#        show_retry_button: true,
#        technical_details: "GoatService::NetworkError: ..."
#      }

module MigrationErrorHelper
  I18N_SCOPE = "migrations.error_messages".freeze

  # Localised text for this helper; key is relative to migrations.error_messages
  def self.t(key, **values)
    I18n.t(key, scope: I18N_SCOPE, **values)
  end

  # Main entry point - explains the current error state
  def self.explain_error(migration)
    return nil unless migration.last_error.present?

    error_message = migration.last_error
    job_step = migration.current_job_step
    retry_attempt = migration.current_job_attempt || 0
    max_attempts = migration.current_job_max_attempts || 3

    # Prefer structured error_code; fall back to regex detection for old records
    error_type = if migration.respond_to?(:error_code) && migration.error_code.present?
      migration.error_code.to_sym
    else
      detect_error_type(error_message)
    end

    # Build context based on error type and migration stage
    context = build_error_context(
      error_type: error_type,
      error_message: error_message,
      migration: migration,
      job_step: job_step,
      retry_attempt: retry_attempt,
      max_attempts: max_attempts
    )

    context
  end

  # Detect error type from error message
  #
  # Each pattern is anchored (\A) or uses phrases unique to one mark_failed! call
  # site so that error types never cross-match. See the comments for the exact
  # messages each pattern targets.
  def self.detect_error_type(error_message)
    case error_message
    when /rate limit|429|RateLimitExceeded/i
      :rate_limit

    # --- PLC-related errors (most specific first) ---

    # PLC OTP token expired or missing (UpdatePlcJob early-return checks)
    #   "PLC token has expired (expired at: ...). Please request a new token."
    #   "PLC token is missing. Please request a new token."
    #   "PLC confirmation code expired. The code from your old PDS..."
    when /\APLC token has expired/, /\APLC token is missing/, /\APLC confirmation code expired/
      :plc_token_expired

    # Post-submission critical PLC failure (UpdatePlcJob rescue, plc_submitted=true)
    #   "CRITICAL: PLC update failed after submission - ..."
    when /\ACRITICAL: PLC update failed after submission/
      :critical_plc

    # Pre-submission recoverable PLC failure (UpdatePlcJob rescue, plc_submitted=false)
    #   "PLC update failed (before submission) - ..."
    when /\APLC update failed \(before submission\)/
      :plc_pre_submission_failure

    # --- Credential / auth errors ---

    # Credentials expired — need re-authentication (UpdatePlcJob credential check)
    #   "Credentials expired: ... no longer available. Please re-authenticate to continue."
    when /\ACredentials expired:.*re-authenticate/
      :credentials_need_reauth

    # Authentication failure (wrong password, 401, etc.)
    when /authentication|unauthorized|401|invalid password/i
      :authentication

    # --- Infrastructure / data errors ---

    when /network|timeout|connection|unreachable/i
      :network
    when /already exists|AlreadyExists|orphaned/i
      :account_exists
    when /invite.*code/i
      :invite_code
    when /blob.*not found|404/i
      :blob_not_found
    when /corrupt|invalid.*format|parse error/i
      :data_corruption
    when /disk.*full|out of space|no space/i
      :disk_space
    when /cancelled by user/i
      :cancelled

    # Legacy catch-all for older "CRITICAL:" PLC messages (before pre/post split)
    when /\ACRITICAL:.*PLC/
      :critical_plc

    else
      :generic
    end
  end

  # Build user-friendly error context
  def self.build_error_context(error_type:, error_message:, migration:, job_step:, retry_attempt:, max_attempts:)
    base_context = case error_type
    when :rate_limit
      rate_limit_context(migration, retry_attempt, max_attempts)
    when :network
      network_context(migration, retry_attempt, max_attempts)
    when :plc_token_expired
      plc_token_expired_context(migration)
    when :plc_pre_submission_failure
      plc_pre_submission_failure_context(migration)
    when :credentials_need_reauth
      credentials_need_reauth_context(migration)
    when :authentication
      authentication_context(migration)
    when :account_exists
      account_exists_context(migration)
    when :blob_not_found
      blob_not_found_context(migration)
    when :data_corruption
      data_corruption_context(migration, retry_attempt, max_attempts)
    when :disk_space
      disk_space_context(migration)
    when :invite_code
      invite_code_context(migration)
    when :email_taken
      email_taken_context(migration)
    when :cancelled
      cancelled_context(migration)
    when :critical_plc
      critical_plc_context(migration)
    else
      generic_context(migration, retry_attempt, max_attempts)
    end

    # Add technical details
    base_context[:technical_details] = error_message
    base_context[:job_step] = job_step

    # Only include retry info when the error type supports automatic retries
    unless base_context[:show_retry_info] == false
      base_context[:retry_info] = {
        attempt: retry_attempt,
        max_attempts: max_attempts,
        remaining: [max_attempts - retry_attempt, 0].max
      }
    end

    base_context
  end

  # Error context builders for each type

  def self.rate_limit_context(migration, retry_attempt, max_attempts)
    {
      severity: :warning,
      icon: "⚠️",
      title: t("rate_limit.title"),
      what_happened: t("rate_limit.what_happened"),
      current_status: retry_attempt < max_attempts ? t("rate_limit.current_status.retrying", attempt: retry_attempt, max_attempts: max_attempts) : t("rate_limit.current_status.exhausted"),
      what_to_do: [
        t("rate_limit.what_to_do.wait"),
        t("rate_limit.what_to_do.temporary"),
        t("rate_limit.what_to_do.overloaded", max_attempts: max_attempts)
      ],
      show_retry_button: retry_attempt >= max_attempts,
      help_link: "/docs/troubleshooting#rate-limiting"
    }
  end

  def self.network_context(migration, retry_attempt, max_attempts)
    stage_info = case migration.status
    when 'pending_repo'
      { stage: "repo_export", url: migration.old_pds_host }
    when 'pending_blobs'
      { stage: "blob_download", url: migration.old_pds_host }
    when 'pending_activation'
      { stage: "account_activation", url: migration.new_pds_host }
    else
      { stage: "other", url: migration.old_pds_host }
    end

    {
      severity: :warning,
      icon: "🌐",
      title: t("network.title"),
      what_happened: t("network.what_happened.#{stage_info[:stage]}"),
      current_status: retry_attempt < max_attempts ? t("network.current_status.retrying", attempt: retry_attempt, max_attempts: max_attempts) : t("network.current_status.exhausted"),
      what_to_do: [
        t("network.what_to_do.wait"),
        t("network.what_to_do.check_url", url: stage_info[:url]),
        t("network.what_to_do.may_be_down"),
        t("network.what_to_do.contact_admin")
      ],
      show_retry_button: retry_attempt >= max_attempts,
      help_link: "/docs/troubleshooting#network-errors",
      check_url: stage_info[:url]
    }
  end

  def self.authentication_context(migration)
    {
      severity: :error,
      icon: "🔐",
      title: t("authentication.title"),
      what_happened: t("authentication.what_happened"),
      current_status: t("authentication.current_status"),
      what_to_do: [
        t("authentication.what_to_do.check_password"),
        t("authentication.what_to_do.check_expiry"),
        t("authentication.what_to_do.start_new"),
        t("authentication.what_to_do.contact_admin")
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_new_migration_button: true,
      help_link: "/docs/troubleshooting#authentication-errors",
      credentials_expire_at: migration.credentials_expires_at
    }
  end

  def self.email_taken_context(migration)
    contact_email = migration.target_pds_contact_email.presence || ENV.fetch('SUPPORT_EMAIL', 'support@example.com')

    {
      severity: :error,
      icon: "📧",
      title: t("email_taken.title"),
      what_happened: t("email_taken.what_happened",
                       new_pds: migration.new_pds_host, email: migration.email, old_pds: migration.old_pds_host),
      current_status: t("email_taken.current_status"),
      what_to_do: [
        t("email_taken.what_to_do.account_is_yours", new_pds: migration.new_pds_host),
        t("email_taken.what_to_do.other_email"),
        t("email_taken.what_to_do.contact_provider", contact_email: contact_email)
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_contact_support: true,
      support_email: contact_email,
      migration_token: migration.token,
      did: migration.did
    }
  end

  # The new-account password (migration_out) was rejected by the target PDS,
  # typically because the user reset it there while the migration was pending
  # (which also revokes the sessions we stored).
  def self.new_pds_login_failed?(migration)
    migration.migration_out? &&
      migration.last_error.to_s.match?(/login to new PDS|new PDS password|Invalid identifier or password/i)
  end

  def self.account_exists_context(migration)
    contact_email = migration.target_pds_contact_email.presence || ENV.fetch('SUPPORT_EMAIL', 'support@example.com')

    {
      severity: :error,
      icon: "👥",
      title: t("account_exists.title"),
      what_happened: t("account_exists.what_happened", new_pds: migration.new_pds_host),
      current_status: t("account_exists.current_status"),
      what_to_do: [
        t("account_exists.what_to_do.contact_provider"),
        t("account_exists.what_to_do.contact_email", contact_email: contact_email),
        t("account_exists.what_to_do.include_details", token: migration.token, did: migration.did),
        "",
        t("account_exists.what_to_do.retry_after_removal"),
        "",
        t("account_exists.what_to_do.provider_only")
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_contact_support: true,
      support_email: contact_email,
      migration_token: migration.token,
      help_link: "/docs/troubleshooting#orphaned-accounts",
      did: migration.did
    }
  end

  def self.plc_token_expired_context(migration)
    {
      severity: :warning,
      icon: "⏰",
      title: t("plc_token_expired.title"),
      what_happened: t("plc_token_expired.what_happened"),
      current_status: t("plc_token_expired.current_status"),
      what_to_do: [
        t("plc_token_expired.what_to_do.request_token", button: request_plc_token_label),
        t("plc_token_expired.what_to_do.check_email", old_pds: migration.old_pds_host),
        t("plc_token_expired.what_to_do.submit_in_time"),
        t("plc_token_expired.what_to_do.data_safe")
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_request_new_plc_token: true,
      help_link: "/docs/troubleshooting#plc-token-expiration",
      expired_at: migration.credentials_expires_at,
      old_pds_host: migration.old_pds_host
    }
  end

  def self.plc_pre_submission_failure_context(migration)
    {
      severity: :warning,
      icon: "⚠️",
      title: t("plc_pre_submission_failure.title"),
      what_happened: t("plc_pre_submission_failure.what_happened", old_pds: migration.old_pds_host),
      current_status: t("plc_pre_submission_failure.current_status"),
      what_to_do: [
        t("plc_pre_submission_failure.what_to_do.request_code", button: request_plc_token_label),
        t("plc_pre_submission_failure.what_to_do.check_email", old_pds: migration.old_pds_host),
        t("plc_pre_submission_failure.what_to_do.submit_in_time"),
        t("plc_pre_submission_failure.what_to_do.data_safe")
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_request_new_plc_token: true,
      show_new_pds_reauth_form: new_pds_login_failed?(migration),
      help_link: "/docs/troubleshooting#plc-token-expiration",
      old_pds_host: migration.old_pds_host
    }
  end

  def self.credentials_need_reauth_context(migration)
    {
      severity: :warning,
      icon: "🔑",
      title: t("credentials_need_reauth.title"),
      what_happened: t("credentials_need_reauth.what_happened"),
      current_status: t("credentials_need_reauth.current_status"),
      what_to_do: [
        t("credentials_need_reauth.what_to_do.enter_password"),
        t("credentials_need_reauth.what_to_do.data_safe"),
        t("credentials_need_reauth.what_to_do.resume")
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_reauth_form: true,
      show_new_pds_reauth_form: new_pds_login_failed?(migration),
      help_link: "/docs/troubleshooting#credential-expiration",
      old_pds_host: migration.old_pds_host
    }
  end

  def self.blob_not_found_context(migration)
    {
      severity: :warning,
      icon: "🖼️",
      title: t("blob_not_found.title"),
      what_happened: t("blob_not_found.what_happened"),
      current_status: t("blob_not_found.current_status"),
      what_to_do: [
        t("blob_not_found.what_to_do.not_critical"),
        t("blob_not_found.what_to_do.media_may_be_missing"),
        t("blob_not_found.what_to_do.check_report"),
        t("blob_not_found.what_to_do.reupload")
      ],
      show_retry_button: false,
      show_download_manifest: true,
      help_link: "/docs/troubleshooting#missing-blobs"
    }
  end

  def self.data_corruption_context(migration, retry_attempt, max_attempts)
    {
      severity: :warning,
      icon: "💾",
      title: t("data_corruption.title"),
      what_happened: t("data_corruption.what_happened"),
      current_status: retry_attempt < max_attempts ? t("data_corruption.current_status.retrying", attempt: retry_attempt, max_attempts: max_attempts) : t("data_corruption.current_status.exhausted"),
      what_to_do: [
        t("data_corruption.what_to_do.wait"),
        t("data_corruption.what_to_do.check_network"),
        t("data_corruption.what_to_do.stable_network"),
        t("data_corruption.what_to_do.large_repositories")
      ],
      show_retry_button: retry_attempt >= max_attempts,
      help_link: "/docs/troubleshooting#data-corruption"
    }
  end

  def self.disk_space_context(migration)
    {
      severity: :error,
      icon: "💿",
      title: t("disk_space.title"),
      what_happened: t("disk_space.what_happened"),
      current_status: t("disk_space.current_status"),
      what_to_do: [
        t("disk_space.what_to_do.contact_admin"),
        t("disk_space.what_to_do.server_side"),
        t("disk_space.what_to_do.retry_later")
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_contact_admin: true,
      help_link: "/docs/troubleshooting#disk-space"
    }
  end

  def self.invite_code_context(migration)
    {
      severity: :error,
      icon: "🎫",
      title: t("invite_code.title"),
      what_happened: t("invite_code.what_happened"),
      current_status: t("invite_code.current_status"),
      what_to_do: [
        t("invite_code.what_to_do.get_new_code"),
        t("invite_code.what_to_do.check_copy"),
        t("invite_code.what_to_do.start_new"),
        t("invite_code.what_to_do.may_not_be_needed")
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_new_migration_button: true,
      help_link: "/docs/troubleshooting#invite-codes"
    }
  end

  def self.cancelled_context(migration)
    {
      severity: :warning,
      icon: "🚫",
      title: t("cancelled.title"),
      what_happened: t("cancelled.what_happened"),
      current_status: t("cancelled.current_status", old_pds: migration.old_pds_host),
      what_to_do: [
        t("cancelled.what_to_do.account_safe", old_pds: migration.old_pds_host),
        t("cancelled.what_to_do.start_new")
      ],
      show_retry_button: false,
      show_retry_info: false,
      show_new_migration_button: true
    }
  end

  def self.critical_plc_context(migration)
    # Check if PLC operation was actually submitted to the directory.
    # The rotation key is generated BEFORE submission as a safety net,
    # so its presence does NOT mean the PLC was updated.
    plc_not_yet_updated = migration.progress_data&.dig('plc_operation_submitted_at').blank?
    support_email = ENV.fetch('SUPPORT_EMAIL', 'support@example.com')

    base_context = {
      severity: :critical,
      icon: "⚠️",
      title: t("critical_plc.title"),
      what_happened: t("critical_plc.what_happened"),
      current_status: plc_not_yet_updated ? t("critical_plc.current_status.not_updated") : t("critical_plc.current_status.maybe_updated"),
      what_to_do: [
        t("critical_plc.what_to_do.no_new_migration"),
        t("critical_plc.what_to_do.data_safe"),
        migration.rotation_key.present? ? t("critical_plc.what_to_do.save_recovery_key") : nil,
        t("critical_plc.what_to_do.save_token", token: migration.token),
        t("critical_plc.what_to_do.contact_support", support_email: support_email)
      ].compact,
      show_retry_button: false,
      show_retry_info: false,
      show_contact_support: true,
      show_rotation_key: true,
      show_request_new_plc_token: true,  # Always show for PLC failures - user may need new token
      help_link: "/docs/troubleshooting#critical-plc-failure",
      migration_token: migration.token,
      support_email: support_email
    }

    # If PLC was not yet updated, emphasize token request
    if plc_not_yet_updated
      base_context[:what_to_do].unshift(t("critical_plc.what_to_do.request_token"))
    end

    base_context
  end

  def self.generic_context(migration, retry_attempt, max_attempts)
    {
      severity: :warning,
      icon: "⚠️",
      title: t("generic.title"),
      what_happened: t("generic.what_happened"),
      current_status: retry_attempt < max_attempts ? t("generic.current_status.retrying", attempt: retry_attempt, max_attempts: max_attempts) : t("generic.current_status.exhausted"),
      what_to_do: [
        t("generic.what_to_do.wait"),
        t("generic.what_to_do.check_details"),
        t("generic.what_to_do.contact_support", support_email: ENV.fetch('SUPPORT_EMAIL', 'support@example.com'))
      ],
      show_retry_button: retry_attempt >= max_attempts,
      help_link: "/docs/troubleshooting"
    }
  end

  # Helper methods

  # Label of the "Request new PLC token" button under the explanation, so the
  # instructions name it exactly as the page shows it in every locale.
  def self.request_plc_token_label
    I18n.t("migrations.error_details.request_plc_action")
  end

  def self.time_until_retry(migration)
    # Calculate next retry time based on exponential backoff
    # This would need to integrate with Sidekiq's retry schedule
    # For now, return estimated times
    attempt = migration.current_job_attempt || 0
    base_delay = 2 # seconds

    case attempt
    when 0, 1
      base_delay * (2 ** attempt)
    when 2
      base_delay * (2 ** attempt)
    else
      30 # polynomial backoff approximation
    end
  end

  def self.format_time_remaining(seconds)
    return t("time_remaining.a_few_moments") if seconds < 5

    if seconds < 60
      t("time_remaining.seconds", count: seconds)
    elsif seconds < 3600
      minutes = (seconds / 60).round
      t("time_remaining.minutes", count: minutes)
    else
      hours = (seconds / 3600).round
      t("time_remaining.hours", count: hours)
    end
  end
end
