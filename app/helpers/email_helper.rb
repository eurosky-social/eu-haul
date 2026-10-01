# frozen_string_literal: true

# Building blocks for the HTML emails (layouts/mailer.html.erb and
# migration_mailer/*.html.erb), which follow the Eurosky design system.
#
# Mail clients drop <style> blocks and CSS variables, so every style here is
# inline and every colour a hex value. Boxes are single-cell tables because
# Outlook ignores padding, borders and backgrounds on divs.
#
# Vertical rhythm: every block element is followed by a gap (16px for most),
# except the last one in the card, a box, a list item or the footer, which
# sits flush against its container's own padding. An element can't know it is
# the last one while it renders, so it writes a placeholder into its style
# (#email_gap) and the enclosing container swaps in the margin once its
# content is complete (#email_gap_scope).
module EmailHelper
  INK = '#1a1a1a'
  MUTED = '#6e6e6c'
  COTTON = '#f7f6f2'
  CARD = '#ffffff'
  LINE = '#e0ddd8'
  WELL = '#eceae5'
  WARNING = '#f7d204'
  SANS = "Inter,'Helvetica Neue',Arial,sans-serif"
  MONO = "'IBM Plex Mono','SF Mono',Menlo,Consolas,monospace"

  TEXT_STYLE = "font-family:#{SANS};font-size:14px;line-height:1.5;color:#{INK};"
  # Long URLs and error strings break instead of widening the card on phones.
  WRAP_STYLE = 'overflow-wrap:break-word;word-wrap:break-word;'
  TABLE_ATTRIBUTES = { role: 'presentation', width: '100%', cellpadding: 0, cellspacing: 0, border: 0 }.freeze
  GAP_PLACEHOLDER = /__email_gap_\d+__/

  # Header above the card: the operator's logo (LOGO_URL), else the site name.
  def email_brand
    if EuroskyConfig::LOGO_URL.present?
      tag.img(src: email_absolute_url(EuroskyConfig::LOGO_URL), alt: EuroskyConfig::SITE_NAME, height: 24,
              style: 'display:block;height:24px;width:auto;border:0;outline:none;text-decoration:none;')
    else
      tag.span(EuroskyConfig::SITE_NAME, style: "font-family:#{SANS};font-size:16px;font-weight:600;line-height:24px;color:#{INK};")
    end
  end

  # A URL a mail client can load: relative paths (/eurosky-logo.png) are
  # resolved against the mailer's default_url_options host and protocol.
  def email_absolute_url(url)
    url = url.to_s
    return url if url.match?(%r{\Ahttps?://}i)
    return "https:#{url}" if url.start_with?('//')

    options = ActionMailer::Base.default_url_options || {}
    host = options[:host].to_s.sub(%r{\Ahttps?://}i, '').chomp('/')
    return url if host.empty?

    protocol = options[:protocol].presence&.to_s&.sub(%r{:?/*\z}, '') || 'http'
    port = ":#{options[:port]}" if options[:port].present? && !host.include?(':')
    "#{protocol}://#{host}#{port}#{'/' unless url.start_with?('/')}#{url}"
  end

  # The card's content, the template's output with its gaps resolved. Called
  # by the layout only.
  def email_card_body(content)
    email_resolve_gaps(content, email_gap_scopes.first)
  end

  # Content shown below the card, on the page background.
  def email_footer(&block)
    content_for(:email_footer, email_gap_scope { capture(&block) })
  end

  # The card-header label: tiny mono capitals over a rule.
  def email_label(text)
    email_block(:p, text, gap: 20,
                style: "padding:0 0 10px 0;border-bottom:1px solid #{INK};font-family:#{MONO};font-size:10px;line-height:1.4;" \
                       "font-weight:400;letter-spacing:0.06em;text-transform:uppercase;color:#{INK};")
  end

  # The mail's main heading.
  def email_title(text)
    email_block(:h1, text, gap: 16,
                style: "font-family:#{SANS};font-size:24px;font-weight:500;letter-spacing:-0.015em;line-height:1.15;color:#{INK};")
  end

  # A section heading, in the card or in a box.
  def email_heading(text)
    email_block(:h2, text, gap: 8, style: "font-family:#{SANS};font-size:16px;font-weight:600;line-height:1.3;color:#{INK};")
  end

  # A paragraph. muted: secondary text; small: 12px secondary text (footer,
  # fine print). Takes the content as an argument or a block.
  def email_text(content = nil, muted: false, small: false, &block)
    content = capture(&block) if block
    color = muted || small ? MUTED : INK
    email_block(:p, content, gap: small ? 8 : 16,
                style: "font-family:#{SANS};font-size:#{small ? 12 : 14}px;line-height:1.5;color:#{color};#{WRAP_STYLE}")
  end

  # A bulleted (or, with ordered: true, numbered) list. Items come as an array
  # or, for items with markup or blocks inside, as email_list_item calls in a
  # block.
  def email_list(items = nil, ordered: false, small: false, &block)
    content = email_gap_scope do
      block ? capture(&block) : safe_join(Array(items).map { |item| email_list_item(item, small: small) })
    end
    email_block(ordered ? :ol : :ul, content, gap: small ? 8 : 16,
                style: "padding:0 0 0 20px;font-family:#{SANS};font-size:#{small ? 12 : 14}px;line-height:1.5;color:#{small ? MUTED : INK};")
  end

  # One item of email_list, with its content as an argument or a block.
  def email_list_item(content = nil, small: false, &block)
    content = email_gap_scope { capture(&block) } if block
    email_block(:li, content, gap: 4,
                style: "font-family:#{SANS};font-size:#{small ? 12 : 14}px;line-height:1.5;color:#{small ? MUTED : INK};#{WRAP_STYLE}")
  end

  # A translation whose values carry markup (email_code, email_link,
  # tag.strong). The translation and every plain value are escaped, values
  # that are already safe go in as they are, and the result is safe to output.
  # Plain-text parts use t() with raw values instead.
  def email_t(key, **values)
    template = ERB::Util.html_escape(t(key)).to_str
    escaped = values.transform_values { |value| ERB::Util.html_escape(value).to_str }
    I18n.interpolate(template, escaped).html_safe
  end

  # "Label: value" in the reader's language (mailers.common.label_value).
  def email_label_value(label, value)
    email_t('mailers.common.label_value', label: label, value: value)
  end

  # A date and time without words (2026-10-02 14:30 UTC), so it reads the same
  # in every language; the status page uses the same format. Takes a Time or
  # an ISO 8601 string, and returns anything it cannot read unchanged.
  def email_time(value)
    time = value.is_a?(String) ? (Time.zone.parse(value) rescue nil) : value
    time ? time.utc.strftime('%Y-%m-%d %H:%M UTC') : value
  end

  # The stage each migration job runs, as MigrationsController#status_from_job_step
  # maps it.
  JOB_STEP_STATUSES = {
    /DownloadAllDataJob/i => 'pending_download',
    /CreateBackupBundleJob/i => 'pending_backup',
    /CreateAccountJob/i => 'pending_account',
    /UploadRepoJob|ImportRepoJob/i => 'pending_repo',
    /UploadBlobsJob|ImportBlobsJob/i => 'pending_blobs',
    /ImportPrefsJob/i => 'pending_prefs',
    /WaitForPlcTokenJob|UpdatePlcJob/i => 'pending_plc',
    /ActivateAccountJob/i => 'pending_activation'
  }.freeze

  # The step a migration failed at (a job class name or a status) in the
  # status page's words (migrations.show.status_names): "UploadBlobsJob" reads
  # "Transferring media". Nil when there is no step to name: a status of
  # "failed" or "completed" only says that the migration stopped.
  def email_step_name(step)
    step = step.to_s
    status = JOB_STEP_STATUSES.find { |pattern, _| step.match?(pattern) }&.last || step
    return nil if status.blank? || Migration::TERMINAL_STATUSES.include?(status)

    I18n.t(status, scope: 'migrations.show.status_names', default: nil)
  end

  # An inline link.
  def email_link(text, url)
    link_to(text, url, style: "color:#{INK};text-decoration:underline;")
  end

  # An inline code, token, key, DID or handle.
  def email_code(text)
    tag.code(text, style: "font-family:#{MONO};font-size:0.9em;")
  end

  # A long value set apart: rotation keys, DIDs, tokens, error messages
  # (size :small), passwords (:medium) or one-time codes (:large). A caption
  # goes above the value and a note below it, both inside the block. The value
  # selects with one click and breaks anywhere; break_all: false keeps words
  # whole where it can (error messages).
  def email_code_block(value, size: :small, caption: nil, note: nil, break_all: true)
    value_style = case size
                  when :large then 'font-size:24px;line-height:1.3;letter-spacing:0.2em;text-indent:0.2em;text-align:center;'
                  when :medium then 'font-size:16px;line-height:1.4;text-align:center;'
                  else 'font-size:12px;line-height:1.5;'
                  end
    padding = size == :small ? 12 : 16
    background = email_inside_well? ? CARD : WELL
    small_text = "font-family:#{SANS};font-size:12px;line-height:1.5;color:#{MUTED};text-align:#{size == :small ? 'left' : 'center'};"

    wrapping = break_all ? 'word-break:break-all;' : "#{WRAP_STYLE}word-break:break-word;"
    content = tag.div(value, style: "font-family:#{MONO};color:#{INK};#{wrapping}-webkit-user-select:all;user-select:all;#{value_style}")
    content = tag.p(caption, style: "margin:0 0 8px 0;#{small_text}") + content if caption.present?
    content += tag.p(note, style: "margin:8px 0 0 0;#{small_text}") if note.present?
    email_table_box(content, gap: 16, cell_style: "background-color:#{background};border-radius:4px;padding:#{padding}px;",
                             bgcolor: background)
  end

  # A bulletproof button: the accent for the mail's main action, outlined
  # (secondary: true) for the others.
  def email_button(text, url, secondary: false)
    background = secondary ? CARD : EuroskyConfig.accent_hex
    color = secondary ? INK : EuroskyConfig.accent_text_color
    border = secondary ? "border:1px solid #{INK};" : ''
    padding = secondary ? '11px 19px' : '12px 20px'

    link = link_to(text, url, style: "display:inline-block;padding:#{padding};font-family:#{SANS};font-size:14px;font-weight:500;" \
                                     "line-height:1.2;color:#{color};text-decoration:none;border-radius:4px;")
    cell = tag.td(link, bgcolor: background, style: "background-color:#{background};#{border}border-radius:4px;")
    email_block(:table, tag.tr(cell), gap: 16, style: 'border-collapse:separate;',
                **TABLE_ATTRIBUTES.merge(width: nil))
  end

  # Something the reader must not miss: a yellow rule on the left. Replaces
  # every red, orange and yellow alert box; the design has no red.
  def email_warning(&block)
    email_table_box(email_gap_scope { capture(&block) }, gap: 16,
                    cell_style: "border-left:3px solid #{WARNING};padding:0 0 0 16px;")
  end

  # A neutral box for information and tips.
  def email_well(&block)
    @_email_well_depth = (@_email_well_depth || 0) + 1
    content = email_gap_scope { capture(&block) }
    @_email_well_depth -= 1
    email_table_box(content, gap: 16, cell_style: "background-color:#{WELL};border-radius:4px;padding:16px;", bgcolor: WELL)
  end

  # A key/value list, filled with email_detail_row / email_detail_line.
  def email_details(&block)
    email_block(:table, capture(&block), gap: 16, style: "width:100%;border-collapse:collapse;border-top:1px solid #{INK};",
                                         **TABLE_ATTRIBUTES)
  end

  # A row of email_details: the label on the left, the value (in mono unless
  # mono: false) on the right.
  def email_detail_row(label, value, mono: true)
    cell = "padding:10px 0;border-bottom:1px solid #{LINE};line-height:1.5;vertical-align:top;"
    value_font = mono ? "font-family:#{MONO};font-size:13px;word-break:break-all;" : "font-family:#{SANS};font-size:14px;#{WRAP_STYLE}"
    tag.tr(
      tag.td(label, width: '30%', valign: 'top', style: "#{cell}width:30%;padding-right:12px;font-family:#{SANS};font-size:14px;color:#{MUTED};") +
      tag.td(value, valign: 'top', style: "#{cell}#{value_font}color:#{INK};")
    )
  end

  # A row of email_details holding one whole line, for translations that
  # carry their label and value in one string ("DID: %{did}").
  def email_detail_line(content)
    tag.tr(tag.td(content, colspan: 2, style: "padding:10px 0;border-bottom:1px solid #{LINE};vertical-align:top;#{TEXT_STYLE}#{WRAP_STYLE}"))
  end

  # A thin rule between two sections of the card.
  def email_divider
    email_table_box('&nbsp;'.html_safe, gap: 24,
                    cell_style: "height:1px;font-size:1px;line-height:1px;border-top:1px solid #{LINE};padding:0;")
  end

  private

  # content_tag with a gap placeholder in front of the style.
  def email_block(name, content, gap:, style:, **attributes)
    content_tag(name, content, **attributes.compact, style: "#{email_gap(gap)}#{style}")
  end

  # A one-cell table, for anything with a background, border or padding.
  def email_table_box(content, gap:, cell_style:, bgcolor: nil)
    cell = tag.td(content, bgcolor: bgcolor, style: cell_style)
    email_block(:table, tag.tr(cell), gap: gap, style: 'width:100%;border-collapse:separate;', **TABLE_ATTRIBUTES)
  end

  def email_inside_well?
    @_email_well_depth.to_i.positive?
  end

  # A placeholder for an element's bottom margin of px pixels, registered with
  # the innermost open container.
  def email_gap(px)
    @_email_gap_count = (@_email_gap_count || 0) + 1
    id = "__email_gap_#{@_email_gap_count}__"
    (@_email_gap_sizes ||= {})[id] = px
    email_gap_scopes.last << id
    id
  end

  # The stack of open containers; the bottom one is the card.
  def email_gap_scopes
    @_email_gap_scopes ||= [[]]
  end

  # Opens a container for the elements rendered in the block, then resolves
  # their gaps.
  def email_gap_scope
    email_gap_scopes.push([])
    html = yield
    email_resolve_gaps(html, email_gap_scopes.pop)
  end

  # Swaps each placeholder for its margin. The container's last element (the
  # one registered last, which is not always the last placeholder in the
  # markup: a list registers after the items inside it) gets none.
  def email_resolve_gaps(html, ids)
    html = String.new(html.to_s)
    last = ids.reverse.find { |id| html.include?(id) }
    html.gsub(GAP_PLACEHOLDER) do |id|
      id == last ? 'margin:0;' : "margin:0 0 #{@_email_gap_sizes.fetch(id, 16)}px 0;"
    end.html_safe
  end
end
