class ApplicationController < ActionController::Base
  # This app was originally API-only but needs HTML views for the migration interface
  # Skip CSRF protection since we use token-based access instead
  skip_before_action :verify_authenticity_token
end
