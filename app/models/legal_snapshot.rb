class LegalSnapshot < ApplicationRecord
  DOCUMENT_TYPES = %w[privacy_policy terms_of_service].freeze

  validates :document_type, presence: true, inclusion: { in: DOCUMENT_TYPES }
  validates :content_hash, presence: true
  validates :rendered_content, presence: true
  validates :version_label, presence: true

  scope :for_type, ->(type) { where(document_type: type) }

  # Returns the most recent snapshot for a given document type
  def self.current(document_type)
    for_type(document_type).order(created_at: :desc).first
  end

  # Computes SHA256 of rendered HTML, creates a new snapshot only if content changed.
  # Returns the snapshot (existing or newly created).
  # Handles race conditions from multiple processes booting simultaneously
  # via the unique index on [document_type, content_hash].
  def self.snapshot_if_changed!(document_type, rendered_html)
    hash = Digest::SHA256.hexdigest(rendered_html)

    existing = find_by(document_type: document_type, content_hash: hash)
    return existing if existing

    create!(
      document_type: document_type,
      content_hash: hash,
      rendered_content: rendered_html,
      version_label: Date.current.iso8601
    )
  rescue ActiveRecord::RecordNotUnique
    # Another process created it between our check and insert
    find_by!(document_type: document_type, content_hash: hash)
  end
end
