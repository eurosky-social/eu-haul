require "test_helper"
require "webmock/minitest"

# GoatService Two-Factor Authentication Tests
#
# Tests for the TwoFactorRequiredError class defined in GoatService.
#
# 2FA flow: The controller's authenticate_and_fetch_profile method calls
# createSession with an optional authFactorToken. If the PDS returns
# "AuthFactorTokenRequired", the controller raises TwoFactorRequiredError.
# After initial authentication, GoatService uses token-based auth (refresh
# tokens) for the old PDS, so 2FA is only needed once at form submission.
#
# Full 2FA integration tests: test/controllers/two_factor_controller_test.rb
class GoatServiceTwoFactorAuthTest < ActiveSupport::TestCase
  # ============================================================================
  # TwoFactorRequiredError Class
  # ============================================================================

  test "TwoFactorRequiredError exists and inherits from GoatError" do
    assert defined?(GoatService::TwoFactorRequiredError),
      "TwoFactorRequiredError should be defined"
    assert GoatService::TwoFactorRequiredError < GoatService::GoatError,
      "TwoFactorRequiredError should inherit from GoatError"
  end

  test "TwoFactorRequiredError can be instantiated with a message" do
    error = GoatService::TwoFactorRequiredError.new("Check your email for a sign-in code")
    assert_equal "Check your email for a sign-in code", error.message
  end

  test "TwoFactorRequiredError is not caught by AuthenticationError rescue" do
    # Verify that TwoFactorRequiredError is NOT a subclass of AuthenticationError,
    # so it won't be accidentally caught by rescue AuthenticationError blocks
    refute GoatService::TwoFactorRequiredError < GoatService::AuthenticationError,
      "TwoFactorRequiredError should NOT inherit from AuthenticationError"
  end
end
