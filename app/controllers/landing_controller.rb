# frozen_string_literal: true

# The front page: what moving an account involves, and the way into the wizard
# (migrations#new). Links that already carry wizard input (a handle, a
# destination) go straight to the wizard instead. /how-it-works explains the
# whole process in detail.
class LandingController < ApplicationController
  WIZARD_PARAMS = %w[handle new_pds_host].freeze

  def show
    wizard_params = request.query_parameters.slice(*WIZARD_PARAMS)
    redirect_to new_migration_path(request.query_parameters) if wizard_params.values.any?(&:present?)
  end

  def how_it_works
  end
end
