# frozen_string_literal: true

# LegalDocuments - the Privacy Policy and Terms of Service as this process
# serves them, archived in LegalSnapshot.
#
# A consent must point at exactly what the user was shown, and the newest
# LegalSnapshot row is not that. Every process snapshots the pages at boot, and
# a process without the OPERATOR_* settings (the Sidekiq containers have none)
# renders "UNCONFIGURED" pages. Which row ends up newest depends on boot order,
# and a rendering that matches an older row adds nothing, so the newest row can
# stay wrong for months: from March to October 2026 every consent pointed at an
# UNCONFIGURED Terms of Service.
class LegalDocuments
  # The snapshot of the page as this process renders it now, stored first if
  # this rendering is new.
  def self.snapshot(document_type)
    LegalSnapshot.snapshot_if_changed!(document_type, render(document_type))
  end

  def self.render(document_type)
    ApplicationController.render(template: "legal/#{document_type}", layout: false)
  end
end
