require "test_helper"

# A consent has to point at the legal text the user was shown, whatever other
# snapshot rows exist.
class LegalDocumentsTest < ActiveSupport::TestCase
  test "renders the pages, links included" do
    html = LegalDocuments.render("terms_of_service")

    assert_includes html, %(href="#{Rails.application.routes.url_helpers.root_path}")
    assert_includes html, EuroskyConfig::OPERATOR_NAME
  end

  test "stores a rendering once and hands back the same row afterwards" do
    first = assert_difference("LegalSnapshot.count", 1) { LegalDocuments.snapshot("privacy_policy") }
    second = assert_no_difference("LegalSnapshot.count") { LegalDocuments.snapshot("privacy_policy") }

    assert_equal first, second
    assert_equal LegalDocuments.render("privacy_policy"), first.rendered_content
  end

  test "a newer row with other content does not stand in for what is served" do
    served = LegalDocuments.snapshot("terms_of_service")
    unconfigured = LegalSnapshot.create!(document_type: "terms_of_service", content_hash: Digest::SHA256.hexdigest("x"),
                                         rendered_content: "<p>provided by UNCONFIGURED</p>", version_label: "2026-03-04")

    assert_equal unconfigured, LegalSnapshot.current("terms_of_service")
    assert_equal served, LegalDocuments.snapshot("terms_of_service")
  end
end
