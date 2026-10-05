require "test_helper"

# A migration that stops because the target already has an account with the
# user's email address can't be retried past that. The failure email and the
# one-off follow-up must say how to get out of it, and never "safely retry".
class MigrationMailerEmailTakenTest < ActionMailer::TestCase
  LEGACY_ERROR = "Failed to create account on new PDS: Failed to create account on new PDS: Email already taken: jane@example.eu"

  test "the failure email for a taken address explains the clash instead of offering a retry" do
    mail = MigrationMailer.migration_failed(migration(error_code: "email_taken",
                                                      last_error: "The email address jane@example.eu is already used by another account on https://eurosky.social."))

    [html(mail), text(mail)].each do |body|
      assert_includes body, I18n.t("mailers.email_taken.why_heading")
      assert_includes body, "eurosky.social"
      assert_includes body, "/migrations/new"
      refute_includes body, I18n.t("mailers.migration_failed.note2")
      refute_includes body, I18n.t("mailers.migration_failed.retry_button")
      refute_includes body, I18n.t("mailers.migration_failed.issue1")
    end
  end

  test "an old generic failure with the PDS's email-taken message gets the same explanation" do
    mail = MigrationMailer.migration_failed(migration(error_code: "generic", last_error: LEGACY_ERROR))

    assert_includes html(mail), I18n.t("mailers.email_taken.steps_heading")
    refute_includes html(mail), I18n.t("mailers.migration_failed.note2")
  end

  test "other failures still offer the retry" do
    mail = MigrationMailer.migration_failed(migration(error_code: "generic", last_error: "Net::ReadTimeout"))

    assert_includes html(mail), I18n.t("mailers.migration_failed.retry_button")
    assert_includes text(mail), I18n.t("mailers.migration_failed.note2")
    refute_includes html(mail), I18n.t("mailers.email_taken.why_heading")
  end

  test "the follow-up names the account, the day it was tried and the way out" do
    mail = MigrationMailer.email_taken_followup(migration(error_code: "generic", last_error: LEGACY_ERROR))

    assert_equal ["jane@example.eu"], mail.to
    assert_equal "How to finish moving @jane.bsky.social", mail.subject
    [html(mail), text(mail)].each do |body|
      assert_includes body, "2026-08-21"
      assert_includes body, "/migrations/new"
      assert_includes body, "admin@eurosky.social"
      assert_includes body, I18n.t("mailers.email_taken.step2", handle: "@jane.bsky.social").split(".").first
    end
  end

  test "the follow-up is written in the language the migration was started in" do
    mail = MigrationMailer.email_taken_followup(migration(error_code: "email_taken", last_error: LEGACY_ERROR, locale: "de"))

    assert_equal "So schließen Sie den Umzug von @jane.bsky.social ab", mail.subject
  end

  test "both emails render in every language without missing or raw strings" do
    I18n.available_locales.each do |locale|
      record = migration(error_code: "email_taken", last_error: LEGACY_ERROR, locale: locale.to_s)

      [MigrationMailer.migration_failed(record), MigrationMailer.email_taken_followup(record)].each do |mail|
        [mail.subject, html(mail), text(mail)].each do |body|
          refute_match(/translation missing/i, body, "#{locale}: #{mail.subject}")
          refute_match(/%\{\w+\}/, body, "#{locale}: uninterpolated placeholder")
        end
      end
    end
  end

  private

  def migration(**attributes)
    Migration.new(
      token: "EURO-AB12CD34EF56GH78",
      did: "did:plc:ewvi7nxzyoun6zhxrhs64oiz",
      email: "jane@example.eu",
      old_handle: "jane.bsky.social",
      new_handle: "jane.bsky.social",
      old_pds_host: "https://bsky.social",
      new_pds_host: "https://eurosky.social",
      target_pds_contact_email: "admin@eurosky.social",
      status: "failed",
      current_job_step: "CreateAccountJob",
      retry_count: 3,
      created_at: Time.zone.parse("2026-08-21 06:19:38"),
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
