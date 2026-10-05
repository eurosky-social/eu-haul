# frozen_string_literal: true

# EmailTakenFollowup - a one-off email to the people whose migration stopped
# because their email address already belonged to another account on the
# target PDS, and who never got their account across.
#
# Until CreateAccountJob learned to tell this case apart, it ended as a generic
# failure: three pointless retries, then a failure email saying the migration
# could "safely" be retried. A retry can never get past an address the target
# already has, so most of these people stayed where they were. This finds them
# and sends MigrationMailer#email_taken_followup once per account.
#
# An account (DID) is included when:
#   - its most recent migration is a failed one that ended on the email clash
#     (a later attempt, whatever became of it, supersedes the old failure),
#   - it hasn't had this follow-up yet (SENT_KEY in progress_data), and
#   - its PLC entry still points at the server it tried to leave. Completed
#     migrations are deleted from the database after a few days, so only PLC
#     can tell whether the account has moved since. If PLC can't be asked,
#     the account is skipped rather than mailed blind.
#
# Usage:
#   EmailTakenFollowup.new.call             # dry run: what would be sent
#   EmailTakenFollowup.new.call(send: true) # send, marking each row
class EmailTakenFollowup
  SENT_KEY = 'email_taken_followup_sent_at'

  # outcome: :sent, :would_send, :failed_to_send or a skip reason
  # (:newer_attempt, :already_sent, :already_moved, :moved_elsewhere, :plc_unavailable)
  Result = Struct.new(:migration, :outcome, :detail, keyword_init: true)

  def initialize(since: nil, pause: 1.0, logger: Rails.logger)
    @since = since
    @pause = pause
    @logger = logger
  end

  def call(send: false)
    latest_failures.map do |migration|
      skip = skip_reason(migration)
      next skip if skip

      send ? deliver(migration) : Result.new(migration: migration, outcome: :would_send)
    end
  end

  # The newest email-taken failure per DID. Old rows were filed as "generic"
  # (or carry no code at all), so they are recognised by their message.
  def latest_failures
    scope = Migration.where(status: 'failed')
                     .where("error_code = 'email_taken' OR " \
                            "((error_code IS NULL OR error_code = 'generic') AND " \
                            "(last_error ILIKE '%email already taken%' OR last_error ILIKE '%already used by another account%'))")
    scope = scope.where('created_at >= ?', @since) if @since
    scope.order(created_at: :desc).to_a.uniq(&:did)
  end

  private

  def skip_reason(migration)
    newest_id = Migration.where(did: migration.did).order(created_at: :desc).pick(:id)
    return skipped(migration, :newer_attempt) unless newest_id == migration.id
    return skipped(migration, :already_sent, migration.progress_data&.dig(SENT_KEY)) if migration.progress_data&.dig(SENT_KEY).present?

    current_pds = GoatService.resolve_did_to_pds(migration.did)
    return skipped(migration, :already_moved, current_pds) if GoatService.same_pds_by_address?(current_pds, migration.new_pds_host)
    return skipped(migration, :moved_elsewhere, current_pds) unless GoatService.same_pds_by_address?(current_pds, migration.old_pds_host)

    nil
  rescue GoatService::GoatError => e
    skipped(migration, :plc_unavailable, e.message)
  end

  def skipped(migration, reason, detail = nil)
    Result.new(migration: migration, outcome: reason, detail: detail)
  end

  def deliver(migration)
    MigrationMailer.email_taken_followup(migration).deliver_now
    # update_columns: a marker on a finished row, no validations or updated_at
    migration.update_columns(progress_data: (migration.progress_data || {}).merge(SENT_KEY => Time.current.iso8601))
    @logger.info("[EmailTakenFollowup] Sent follow-up for migration #{migration.token}")
    sleep(@pause) if @pause.positive?
    Result.new(migration: migration, outcome: :sent)
  rescue StandardError => e
    @logger.error("[EmailTakenFollowup] Could not send follow-up for migration #{migration.token}: #{e.class}: #{e.message}")
    Result.new(migration: migration, outcome: :failed_to_send, detail: "#{e.class}: #{e.message}")
  end
end
