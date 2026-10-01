module ApplicationHelper
  PUBLIC_ASSET_DIGESTS = Concurrent::Map.new

  # Path to a file in public/ with a content hash appended, so a deploy that
  # changes a stylesheet is never served from a stale browser cache. eu-haul has
  # no asset pipeline; the hash is computed once per file per process (and again
  # whenever the file changes, which keeps development live).
  def public_asset_path(path)
    file = Rails.public_path.join(path)
    return "/#{path}" unless file.file?

    mtime = file.mtime.to_i
    cached = PUBLIC_ASSET_DIGESTS[path]
    unless cached && cached[:mtime] == mtime
      cached = { mtime: mtime, digest: Digest::SHA256.file(file).hexdigest[0, 12] }
      PUBLIC_ASSET_DIGESTS[path] = cached
    end
    "/#{path}?v=#{cached[:digest]}"
  end

  # The operator's accent (PRIMARY_COLOR) over the design system's green. The
  # normalised hex is used rather than the raw setting, so nothing an operator
  # types can end up verbatim inside a <style> block.
  def accent_style_tag
    accent = EuroskyConfig.accent_hex
    tag.style(<<~CSS.html_safe)
      :root, [data-theme="light"] {
        --es-accent: #{accent};
        --es-accent-hover: color-mix(in srgb, #{accent} 88%, #1a1a1a);
        --es-fg-on-accent: #{EuroskyConfig.accent_text_color};
      }
    CSS
  end

  # "How it works": the operator's own page when HOW_IT_WORKS_URL is set,
  # the built-in /how-it-works otherwise. External pages open in a new tab.
  def how_it_works_link(text, **options)
    if EuroskyConfig::HOW_IT_WORKS_URL.present?
      link_to text, EuroskyConfig::HOW_IT_WORKS_URL, target: '_blank', rel: 'noopener', **options
    else
      link_to text, how_it_works_path, **options
    end
  end

  # Header mark: the operator's logo when LOGO_URL is set, the site name otherwise.
  def brand_mark
    if EuroskyConfig::LOGO_URL.present?
      image_tag EuroskyConfig::LOGO_URL, alt: EuroskyConfig::SITE_NAME, class: 'eh-brand-logo'
    else
      tag.span EuroskyConfig::SITE_NAME, class: 'eh-brand-name'
    end
  end
end
