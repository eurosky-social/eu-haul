# Boot-time legal document snapshotting
#
# On each boot (web and sidekiq processes), renders the Privacy Policy and Terms of Service
# templates, computes a SHA256 hash, and stores a new snapshot if the content has changed.
# This ensures every version of the legal documents is archived without manual intervention.
#
# The unique index on [document_type, content_hash] prevents duplicate snapshots when
# multiple processes boot simultaneously.

Rails.application.config.after_initialize do
  next if Rails.env.test?

  begin
    # Verify the table exists (may not yet if migrations haven't run)
    unless ActiveRecord::Base.connection.table_exists?(:legal_snapshots)
      Rails.logger.warn("LegalSnapshots: legal_snapshots table does not exist yet. Run db:migrate.")
      next
    end

    %w[privacy_policy terms_of_service].each do |doc_type|
      rendered = ApplicationController.render(
        template: "legal/#{doc_type}",
        layout: false
      )

      snapshot = LegalSnapshot.snapshot_if_changed!(doc_type, rendered)
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
