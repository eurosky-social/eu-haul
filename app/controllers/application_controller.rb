class ApplicationController < ActionController::Base
  # This app was originally API-only but needs HTML views for the migration interface
  # Skip CSRF protection since we use token-based access instead
  skip_before_action :verify_authenticity_token

  around_action :switch_locale

  private

  def switch_locale(&action)
    locale = extract_locale || I18n.default_locale
    I18n.with_locale(locale, &action)
  end

  def extract_locale
    # 1. Explicit locale parameter
    if params[:locale].present?
      loc = params[:locale].to_sym
      return loc if I18n.available_locales.include?(loc)
    end

    # 2. Cookie
    if cookies[:locale].present?
      loc = cookies[:locale].to_sym
      return loc if I18n.available_locales.include?(loc)
    end

    # 3. Accept-Language header
    extract_locale_from_accept_language
  end

  def extract_locale_from_accept_language
    return nil unless request.env['HTTP_ACCEPT_LANGUAGE']

    # Parse Accept-Language header and find best match
    preferred = request.env['HTTP_ACCEPT_LANGUAGE']
      .split(',')
      .map { |lang|
        parts = lang.strip.split(';q=')
        [parts[0].strip.downcase, (parts[1] || '1').to_f]
      }
      .sort_by { |_, q| -q }

    preferred.each do |lang, _|
      # Try exact match first (e.g., "nb-NO" -> :nb)
      code = lang.split('-').first.to_sym
      return code if I18n.available_locales.include?(code)
    end

    nil
  end

  def default_url_options
    { locale: (I18n.locale == I18n.default_locale ? nil : I18n.locale) }
  end
end
