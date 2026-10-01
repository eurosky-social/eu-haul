require "test_helper"

# The landing page, the way into the wizard, and the shared layout's branding.
class LandingAndLayoutTest < ActionDispatch::IntegrationTest
  test "the root is the landing page, which leads into the wizard" do
    get root_path

    assert_response :success
    headline = EuroskyConfig::LANDING_DESTINATION ? I18n.t("landing.title_named", name: EuroskyConfig::LANDING_DESTINATION) : I18n.t("landing.title")
    assert_select "h1", headline
    assert_select "a.es-btn-primary[href=?]", new_migration_path
    assert_select "ol.eh-howto li", 3
    assert_select "form#migration-wizard", false
  end

  test "a link that already carries a handle goes straight to the wizard" do
    get root_path, params: { handle: "jane.bsky.social" }

    assert_redirected_to new_migration_path(handle: "jane.bsky.social")
  end

  test "How it works leads to the built-in guide unless HOW_IT_WORKS_URL points elsewhere" do
    get root_path

    target = EuroskyConfig::HOW_IT_WORKS_URL.presence || how_it_works_path
    assert_select ".eh-hero a.es-btn-ghost[href=?]", target, text: I18n.t("landing.how_it_works")
    assert_select "footer a[href=?]", target
  end

  test "the guide explains the move step by step and leads into the wizard" do
    get how_it_works_path

    assert_response :success
    assert_select "h1", I18n.t("how_it_works.title")
    assert_select "section.eh-spec", 4
    assert_select "ol.eh-steplist li", 6
    assert_select "a.es-btn-primary[href=?]", new_migration_path
  end

  test "the wizard has the five steps, a step counter and the leave dialog" do
    get new_migration_path

    assert_response :success
    assert_select "form#migration-wizard"
    assert_select "button.eh-step", 5
    (1..5).each { |n| assert_select "#step-#{n}.wizard-step" }
    assert_select "#wizard-step-count", I18n.t("migrations.new.step_of", current: 1, total: 5)
    assert_select "dialog#leave-dialog"
  end

  test "every page carries the design system, the accent and a light theme" do
    get root_path

    assert_select "html[data-theme=light]"
    %w[fonts/fonts.css eurosky-design/tokens.css eurosky-design/base.css eurosky-design/components.css eu-haul.css].each do |sheet|
      assert_select "link[rel=stylesheet][href^=?]", "/#{sheet}?v="
    end
    assert_includes response.body, "--es-accent: #{EuroskyConfig.accent_hex};"
    assert_includes response.body, "--es-fg-on-accent: #{EuroskyConfig.accent_text_color};"
    assert_select "link[href*=bootstrap]", false
  end

  test "the header shows the logo when one is configured, the site name otherwise" do
    get root_path

    if EuroskyConfig::LOGO_URL.present?
      assert_select "a#eh-home-link img.eh-brand-logo[alt=?]", EuroskyConfig::SITE_NAME
    else
      assert_select "a#eh-home-link .eh-brand-name", EuroskyConfig::SITE_NAME
    end
  end

  test "the legal pages render inside the layout" do
    get privacy_policy_path
    assert_response :success
    assert_select "article.eh-doc h1", "Privacy Policy"
    assert_select "header.eh-topbar"

    get terms_of_service_path
    assert_response :success
    assert_select "article.eh-doc h1", "Terms of Service"
  end
end
