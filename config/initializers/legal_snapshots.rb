# Boot-time legal document snapshotting
#
# On each boot of a process that serves the pages (web, console, runner), renders
# the Privacy Policy and Terms of Service templates, computes a SHA256 hash, and
# stores a new snapshot if the content has changed. This ensures every version of
# the legal documents is archived without manual intervention. Consents don't rely
# on it: they point at the snapshot of what the request renders (LegalDocuments).
#
# Not in Sidekiq, and not in any process without the operator settings (a one-off
# container, say): those render pages reading "UNCONFIGURED" that nobody is
# ever shown, and each deploy would archive another copy of them.
#
# Runs on after_routes_loaded rather than after_initialize: the pages link with
# route helpers (root_path), and Rails draws the routes only after the
# after_initialize callbacks. The hook fires again on every route reload in
# development, so it snapshots once per process.
#
# The unique index on [document_type, content_hash] prevents duplicate snapshots when
# multiple processes boot simultaneously.

snapshotted = false

ActiveSupport.on_load(:after_routes_loaded) do
  next if snapshotted || Rails.env.test?
  next if defined?(Sidekiq) && Sidekiq.server?

  unless EuroskyConfig.legal_pages_configured?
    Rails.logger.info("LegalSnapshots: Skipping — OPERATOR_NAME, EFFECTIVE_DATE or GOVERNING_JURISDICTION is not set in this process")
    next
  end

  snapshotted = true

  begin
    # Verify the table exists (may not yet if migrations haven't run)
    unless ActiveRecord::Base.connection.table_exists?(:legal_snapshots)
      Rails.logger.warn("LegalSnapshots: legal_snapshots table does not exist yet. Run db:migrate.")
      next
    end

    %w[privacy_policy terms_of_service].each do |doc_type|
      snapshot = LegalDocuments.snapshot(doc_type)
      was_new = snapshot.previously_new_record?

      if was_new
        Rails.logger.warn(
          "LegalSnapshots: NEW version detected for #{doc_type} — " \
          "v#{snapshot.version_label} (hash: #{snapshot.content_hash[0..11]}...)"
        )
      else
        Rails.logger.info(
          "LegalSnapshots: #{doc_type} unchanged — " \
          "v#{snapshot.version_label} (hash: #{snapshot.content_hash[0..11]}...)"
        )
      end
    end
  rescue ActiveRecord::NoDatabaseError, ActiveRecord::StatementInvalid => e
    Rails.logger.warn("LegalSnapshots: Skipping — database not ready (#{e.class}: #{e.message})")
  rescue StandardError => e
    Rails.logger.error("LegalSnapshots: Failed to snapshot legal documents — #{e.class}: #{e.message}")
  end
end
