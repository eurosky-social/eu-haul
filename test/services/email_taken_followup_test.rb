require "test_helper"

# EmailTakenFollowup mails each account whose migration stopped on "email
# already taken" once, and only while the account still sits where it was.
class EmailTakenFollowupTest < ActiveSupport::TestCase
  OLD_PDS = "https://shiitake.us-east.host.bsky.network"
  NEW_PDS = "https://eurosky.social"
  LEGACY_ERROR = "Failed to create account on new PDS: Failed to create account on new PDS: Email already taken: jane@example.eu"

  setup { ActionMailer::Base.deliveries.clear }

  test "a dry run lists an old generic failure whose account never moved, and sends nothing" do
    migration = failed_migration("did:plc:taken1")
    # Bluesky moves accounts between its own hosts; that is still "not moved"
    at_pds(migration, "https://enoki.us-east.host.bsky.network")

    assert_equal [[migration, :would_send]], outcomes(EmailTakenFollowup.new(pause: 0).call)
    assert_empty ActionMailer::Base.deliveries
  end

  test "sending mails the address once and marks the row" do
    migration = failed_migration("did:plc:taken2", code: "email_taken",
                                 error: "The email address jane@example.eu is already used by another account on #{NEW_PDS}.")
    at_pds(migration, OLD_PDS)

    assert_equal [[migration, :sent]], outcomes(EmailTakenFollowup.new(pause: 0).call(send: true))
    assert_equal [["jane@example.eu"]], ActionMailer::Base.deliveries.map(&:to)
    assert migration.reload.progress_data[EmailTakenFollowup::SENT_KEY].present?

    assert_equal [[migration, :already_sent]], outcomes(EmailTakenFollowup.new(pause: 0).call(send: true))
    assert_equal 1, ActionMailer::Base.deliveries.size
  end

  test "accounts that have moved since, or can't be checked, are skipped" do
    moved = failed_migration("did:plc:taken3")
    elsewhere = failed_migration("did:plc:taken4")
    unknown = failed_migration("did:plc:taken5")
    at_pds(moved, NEW_PDS)
    at_pds(elsewhere, "https://blacksky.app")
    GoatService.stubs(:resolve_did_to_pds).with(unknown.did).raises(GoatService::NetworkError, "PLC timed out")

    results = EmailTakenFollowup.new(pause: 0).call(send: true)

    assert_equal [[elsewhere, :moved_elsewhere], [moved, :already_moved], [unknown, :plc_unavailable]].sort_by { |m, _| m.id },
                 outcomes(results).sort_by { |m, _| m.id }
    assert_empty ActionMailer::Base.deliveries
  end

  test "a later attempt for the same account supersedes the failure" do
    failure = failed_migration("did:plc:taken6", created_at: 5.days.ago)
    Migration.create!(attributes("did:plc:taken6"))
    GoatService.expects(:resolve_did_to_pds).never

    assert_equal [[failure, :newer_attempt]], outcomes(EmailTakenFollowup.new(pause: 0).call)
  end

  test "only the newest email-taken failure per account counts, and other failures are ignored" do
    failed_migration("did:plc:taken7", created_at: 9.days.ago)
    newest = failed_migration("did:plc:taken7", created_at: 2.days.ago)
    failed_migration("did:plc:taken8", error: "Authentication failed: Invalid password", code: "authentication")
    at_pds(newest, OLD_PDS)

    assert_equal [[newest, :would_send]], outcomes(EmailTakenFollowup.new(pause: 0).call)
  end

  test "a failed delivery is reported and leaves the row unmarked" do
    migration = failed_migration("did:plc:taken9")
    at_pds(migration, OLD_PDS)
    MigrationMailer.stubs(:email_taken_followup).raises(Net::SMTPServerBusy, "try later")

    assert_equal [[migration, :failed_to_send]], outcomes(EmailTakenFollowup.new(pause: 0).call(send: true))
    assert_nil migration.reload.progress_data[EmailTakenFollowup::SENT_KEY]
  end

  private

  def attributes(did)
    { did: did, email: "jane@example.eu", old_handle: "jane.bsky.social", new_handle: "jane.bsky.social",
      old_pds_host: OLD_PDS, new_pds_host: NEW_PDS, migration_type: "migration_out" }
  end

  def failed_migration(did, error: LEGACY_ERROR, code: "generic", created_at: 3.days.ago)
    migration = Migration.create!(attributes(did))
    migration.update_columns(status: "failed", last_error: error, error_code: code, created_at: created_at)
    migration
  end

  def at_pds(migration, pds)
    GoatService.stubs(:resolve_did_to_pds).with(migration.did).returns(pds)
  end

  def outcomes(results)
    results.map { |result| [result.migration, result.outcome] }
  end
end
