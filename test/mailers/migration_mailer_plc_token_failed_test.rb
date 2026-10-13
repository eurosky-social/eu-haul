require "test_helper"

# UpdatePlcJob mails plc_token_failed for every failure before the PLC
# directory is touched. A code the old PDS did not recognise must be told
# apart from one that ran out, and no PLC mail may quote the one-hour lifetime
# the PDS never had: it accepts a code for 15 minutes.
class MigrationMailerPlcTokenFailedTest < ActionMailer::TestCase
  NOT_RECOGNISED = "PLC confirmation code not recognised by your old PDS. Request a new code and enter it exactly as it appears in the newest email."
  EXPIRED = "PLC confirmation code expired. The code from your old PDS is only valid for a limited time. Please request a new one."

  test "a code the old PDS did not recognise gets the not-recognised wording" do
    mail = MigrationMailer.plc_token_failed(migration(error_code: "plc_token_invalid", last_error: NOT_RECOGNISED))

    [html(mail), text(mail)].each do |body|
      assert_includes body, I18n.t("mailers.plc_token_failed.invalid_heading")
      assert_includes body, I18n.t("mailers.plc_token_failed.invalid_what_happened_text")
      refute_includes body, I18n.t("mailers.plc_token_failed.what_happened_text")
      refute_match(/1 hour/, body)
    end
  end

  test "an expired code keeps the expired wording, with the PDS's 15 minutes" do
    mail = MigrationMailer.plc_token_failed(migration(error_code: "plc_token_expired", last_error: EXPIRED))

    [html(mail), text(mail)].each do |body|
      assert_includes body, I18n.t("mailers.plc_token_failed.heading")
      assert_includes body, "15 minutes"
      refute_includes body, I18n.t("mailers.plc_token_failed.invalid_heading")
      refute_match(/1 hour/, body)
    end
  end

  test "a generic pre-submission failure also keeps the expired wording" do
    mail = MigrationMailer.plc_token_failed(migration(error_code: "plc_pre_submission_failure", last_error: "PLC update failed (before submission) - Net::ReadTimeout"))

    assert_includes html(mail), I18n.t("mailers.plc_token_failed.heading")
    refute_includes html(mail), I18n.t("mailers.plc_token_failed.invalid_heading")
  end

  test "the reminder names Bluesky as the sender for a Bluesky-hosted account" do
    mail = MigrationMailer.plc_token_reminder(migration(status: "pending_plc", old_pds_host: "https://shimeji.us-east.host.bsky.network"))

    [html(mail), text(mail)].each do |body|
      assert_includes body, "Bluesky (noreply@bsky.app)"
      refute_includes body, "shimeji"
    end
  end

  test "the rotation key notice says 15 minutes and names Bluesky as the sender" do
    record = migration(status: "pending_plc", old_pds_host: "https://shimeji.us-east.host.bsky.network")
    record.set_rotation_key("test-rotation-private-key")
    mail = MigrationMailer.rotation_key_notice(record)

    [html(mail), text(mail)].each do |body|
      assert_includes body, "Bluesky (noreply@bsky.app)"
      assert_includes body, "15 minutes"
      refute_match(/1 hour/, body)
    end
  end

  private

  def migration(**attributes)
    Migration.new(
      token: "EURO-AB12CD34EF56GH78",
      did: "did:plc:ewvi7nxzyoun6zhxrhs64oiz",
      email: "jane@example.eu",
      old_handle: "jane.bsky.social",
      new_handle: "jane.eurosky.social",
      old_pds_host: "https://bsky.social",
      new_pds_host: "https://eurosky.social",
      target_pds_contact_email: "admin@eurosky.social",
      status: "failed",
      current_job_step: "UpdatePlcJob",
      locale: "en",
      **attributes
    )
  end

  def html(mail)
    mail.html_part.body.decoded
  end

  def text(mail)
    mail.text_part.body.decoded
  end
end
